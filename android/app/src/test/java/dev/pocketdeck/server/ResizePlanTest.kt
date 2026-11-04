package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The resize sequence of a window stream: the new encoder exists before the
 * display changes, the display never loses its surface on the way, and a size
 * the encoder rejects never leaves the stream without an encoder.
 */
class ResizePlanTest {

    private class Recorder(
        private val limits: EncoderLimits = EncoderLimits(),
        private val failPrepare: Boolean = false,
        private val shrinkTo: IntSize? = null,
    ) : ResizeSteps {
        val calls = ArrayList<String>()

        override fun fit(w: Int, h: Int): IntSize {
            calls += "fit"
            return EncoderSizes.fit(w, h, limits)
        }

        override fun prepare(size: IntSize): IntSize? {
            calls += "prepare ${size.w}x${size.h}"
            return if (failPrepare) null else shrinkTo ?: size
        }

        override fun resizeDisplay(size: IntSize, dpi: Int) {
            calls += "resizeDisplay ${size.w}x${size.h}@$dpi"
        }

        override fun attachPrepared() {
            calls += "attach"
        }

        override fun releasePrevious() {
            calls += "releasePrevious"
        }
    }

    private val current = IntSize(1792, 1200)

    @Test
    fun `the new encoder is built before the display is touched`() {
        val steps = Recorder()
        val result = ResizeSequencer(steps).resize(2320, 1200, 318, paused = false, current = current)

        assertEquals(ResizeSequencer.Outcome.RESIZED, result.outcome)
        assertEquals(IntSize(2320, 1200), result.size)
        assertEquals(
            listOf("fit", "prepare 2320x1200", "resizeDisplay 2320x1200@318", "attach", "releasePrevious"),
            steps.calls,
        )
    }

    @Test
    fun `the old encoder outlives the display switch`() {
        val steps = Recorder()
        ResizeSequencer(steps).resize(2080, 1200, 318, paused = false, current = current)

        assertTrue(steps.calls.indexOf("attach") < steps.calls.indexOf("releasePrevious"))
        assertTrue(steps.calls.indexOf("prepare 2080x1200") < steps.calls.indexOf("resizeDisplay 2080x1200@318"))
    }

    @Test
    fun `an encoder that cannot be built leaves the stream untouched`() {
        val steps = Recorder(failPrepare = true)
        val result = ResizeSequencer(steps).resize(4000, 2992, 318, paused = false, current = current)

        assertEquals(ResizeSequencer.Outcome.KEPT, result.outcome)
        assertEquals(current, result.size)
        assertEquals(listOf("fit", "prepare 4000x2992"), steps.calls)
    }

    @Test
    fun `the display follows the size the encoder really encodes`() {
        val steps = Recorder(shrinkTo = IntSize(1728, 1072))
        val result = ResizeSequencer(steps).resize(1920, 1200, 320, paused = false, current = current)

        assertEquals(IntSize(1728, 1072), result.size)
        assertTrue(steps.calls.contains("resizeDisplay 1728x1072@320"))
        assertFalse(steps.calls.contains("resizeDisplay 1920x1200@320"))
    }

    @Test
    fun `a paused stream only resizes its display`() {
        val steps = Recorder()
        val result = ResizeSequencer(steps).resize(1024, 1200, 318, paused = true, current = current)

        assertEquals(ResizeSequencer.Outcome.DISPLAY_ONLY, result.outcome)
        assertEquals(listOf("fit", "resizeDisplay 1024x1200@318"), steps.calls)
    }

    @Test
    fun `resume builds an encoder and attaches it`() {
        val steps = Recorder()
        val display = IntSize(1024, 1200)
        val result = ResizeSequencer(steps).resume(1024, 1200, 318, display)

        assertEquals(ResizeSequencer.Outcome.RESIZED, result.outcome)
        assertEquals(listOf("fit", "prepare 1024x1200", "attach", "releasePrevious"), steps.calls)
    }

    @Test
    fun `resume fixes the display when the encoder took another size`() {
        val steps = Recorder(shrinkTo = IntSize(1008, 1184))
        ResizeSequencer(steps).resume(1024, 1200, 318, IntSize(1024, 1200))

        assertEquals(
            listOf("fit", "prepare 1024x1200", "resizeDisplay 1008x1184@318", "attach", "releasePrevious"),
            steps.calls,
        )
    }

    @Test
    fun `resume without an encoder keeps the stream detached`() {
        val steps = Recorder(failPrepare = true)
        val result = ResizeSequencer(steps).resume(1024, 1200, 318, IntSize(1024, 1200))

        assertEquals(ResizeSequencer.Outcome.KEPT, result.outcome)
        assertEquals(listOf("fit", "prepare 1024x1200"), steps.calls)
    }

    // ------------------------------------------------------------------ sizes

    @Test
    fun `sizes are aligned down to 16`() {
        assertEquals(IntSize(2320, 1200), EncoderSizes.fit(2321, 1203, EncoderLimits()))
        assertEquals(IntSize(2080, 1200), EncoderSizes.fit(2095, 1215, EncoderLimits()))
        assertEquals(IntSize(16, 16), EncoderSizes.fit(3, 7, EncoderLimits()))
    }

    @Test
    fun `an already aligned size is untouched`() {
        assertEquals(IntSize(1792, 1200), EncoderSizes.fit(1792, 1200, EncoderLimits()))
    }

    @Test
    fun `a size over the encoder ceiling is scaled down keeping its shape`() {
        val limits = EncoderLimits(maxW = 2048, maxH = 2048)
        assertEquals(IntSize(2048, 1056), EncoderSizes.fit(2320, 1200, limits))
        val tall = EncoderSizes.fit(1200, 4000, EncoderLimits(maxW = 4096, maxH = 2048))
        assertTrue(tall.h <= 2048 && tall.w <= 4096)
        assertEquals(0, tall.w % 16)
        assertEquals(0, tall.h % 16)
    }

    @Test
    fun `a stricter encoder alignment wins`() {
        val size = EncoderSizes.fit(1000, 1000, EncoderLimits(widthAlign = 32, heightAlign = 32))
        assertEquals(IntSize(992, 992), size)
    }

    @Test
    fun `an exact even size passes through the codec's own alignment unchanged`() {
        val limits = EncoderLimits(maxW = 8192, maxH = 8192, widthAlign = 2, heightAlign = 2)
        assertEquals(IntSize(2406, 1386), EncoderSizes.fit(2406, 1386, limits))
        assertEquals(IntSize(1202, 856), EncoderSizes.fit(1202, 856, limits))
    }

    @Test
    fun `an odd size rounds down to the codec's alignment`() {
        val limits = EncoderLimits(maxW = 8192, maxH = 8192, widthAlign = 2, heightAlign = 2)
        assertEquals(IntSize(2406, 1386), EncoderSizes.fit(2407, 1387, limits))
    }

    @Test
    fun `each axis follows its own alignment`() {
        val limits = EncoderLimits(widthAlign = 2, heightAlign = 4)
        assertEquals(IntSize(1202, 856), EncoderSizes.fit(1203, 857, limits))
        assertEquals(IntSize(1202, 856), EncoderSizes.fit(1203, 858, limits))
    }

    @Test
    fun `a size the encoder rejects is shrunk until it takes it`() {
        val size = EncoderSizes.fit(1920, 1200, EncoderLimits()) { w, h -> w * h <= 1_900_000 }
        assertTrue(size.w * size.h <= 1_900_000)
        assertEquals(0, size.w % 16)
        assertEquals(0, size.h % 16)
        assertTrue("not shrunk further than needed", size.w >= 1600)
    }

    // ------------------------------------------------------------------ guard

    @Test
    fun `a stream that never attached is never nudged`() {
        val guard = RedrawGuard()
        assertNull(guard.poll(10_000))
        assertNull(guard.onFrame(10_000))
    }

    @Test
    fun `no nudge before the first check`() {
        val guard = RedrawGuard()
        guard.onAttached(1_000)
        assertNull(guard.poll(1_000))
        assertNull(guard.poll(1_000 + RedrawGuard.FIRST_CHECK_MS - 1))
    }

    @Test
    fun `an idle app gets two nudges, one dpi up then back, and no more`() {
        val guard = RedrawGuard()
        guard.onAttached(1_000)
        val first = 1_000 + RedrawGuard.FIRST_CHECK_MS
        assertEquals(1, guard.poll(first))
        assertNull("spaced by the retry interval", guard.poll(first + 1))
        val second = first + RedrawGuard.RETRY_MS
        assertEquals(0, guard.poll(second))
        assertNull(guard.poll(second + RedrawGuard.RETRY_MS))
        assertEquals(RedrawGuard.MAX_NUDGES, guard.nudgeCount)
    }

    @Test
    fun `a frame stops the nudging and reports its latency once`() {
        val guard = RedrawGuard()
        guard.onAttached(1_000)
        assertEquals(120L, guard.onFrame(1_120))
        assertNull("only the first frame is reported", guard.onFrame(1_130))
        assertNull(guard.poll(5_000))
        assertEquals(0, guard.nudgeCount)
    }

    @Test
    fun `every attach starts a fresh watch`() {
        val guard = RedrawGuard()
        guard.onAttached(0)
        guard.onFrame(50)
        guard.onAttached(10_000)
        assertNull(guard.poll(10_000))
        assertEquals(1, guard.poll(10_000 + RedrawGuard.FIRST_CHECK_MS))
        assertEquals(300L, guard.onFrame(10_300))
    }
}
