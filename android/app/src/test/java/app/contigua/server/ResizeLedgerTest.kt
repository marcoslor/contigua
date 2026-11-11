package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The phone's side of the density burst (the 10-27 report): the Mac sent the
 * same request seven times in 1.2 s, and every one re-attached the encoder until
 * frames stopped for 7 s. A repeat asks for nothing, and a dpi-only change is a
 * display relayout — the encoder keeps its surface and its stream.
 */
class ResizeLedgerTest {

    private val base = ResizeRequest(1600, 1200, 240)
    private val larger = ResizeRequest(1600, 1200, 360)
    private val wider = ResizeRequest(1920, 1200, 240)

    @Test
    fun `the first request for a display is a full resize`() {
        assertEquals(ResizeNeed.FULL, ResizeLedger().need(base))
    }

    @Test
    fun `the same request again asks for nothing`() {
        val ledger = ResizeLedger().remember(base)
        repeat(9) { assertEquals(ResizeNeed.SAME, ledger.need(base)) }
    }

    @Test
    fun `a dpi-only change never rebuilds the encoder`() {
        val ledger = ResizeLedger().remember(base)
        assertEquals(ResizeNeed.DENSITY, ledger.need(larger))
    }

    @Test
    fun `a new size is a full resize`() {
        val ledger = ResizeLedger().remember(base).remember(larger)
        assertEquals(ResizeNeed.FULL, ledger.need(wider))
    }

    @Test
    fun `a request the encoder refused is not remembered as applied`() {
        val ledger = ResizeLedger().remember(base)
        // `kept`: the phone still shows the old size, so the next identical
        // request must try again rather than answer "nothing to do".
        ledger.settle(wider, ResizeOutcome.KEPT)
        assertEquals(ResizeNeed.FULL, ledger.need(wider))
        assertEquals(ResizeNeed.SAME, ledger.need(base))
    }

    @Test
    fun `an unknown display has no applied request`() {
        val ledger = ResizeLedger()
        ledger.settle(base, ResizeOutcome.KEPT)
        assertEquals(ResizeNeed.FULL, ledger.need(base))
    }

    @Test
    fun `a repeat of a request the encoder fitted is a no-op`() {
        // The Mac asks 1000x1000 and the encoder only takes 992x992. Round 1
        // remembered the fitted size, so the same request read as FULL and
        // rebuilt the encoder once more.
        val steps = Recorder()
        steps.fitted = IntSize(992, 992)
        val ledger = ResizeLedger()
        val asked = ResizeRequest(1000, 1000, 240)
        assertEquals(ResizeNeed.FULL, ledger.need(asked))
        val result = ResizeSequencer(steps).resize(asked.w, asked.h, asked.dpi,
                                                  paused = false, current = IntSize(896, 592))
        assertEquals(IntSize(992, 992), result.size)
        assertEquals(ResizeSequencer.Outcome.RESIZED, result.outcome)
        ledger.settle(asked, ResizeOutcome.RESIZED)
        assertEquals(ResizeNeed.SAME, ledger.need(asked))
        assertEquals(ResizeNeed.DENSITY, ledger.need(ResizeRequest(1000, 1000, 300)))
    }

    @Test
    fun `a request that was kept or refused is not remembered`() {
        val ledger = ResizeLedger().remember(ResizeRequest(1000, 1000, 240))
        // The encoder refused a new size: the display still shows the old one.
        ledger.settle(ResizeRequest(1200, 1000, 240), ResizeOutcome.KEPT)
        assertEquals(ResizeNeed.FULL, ledger.need(ResizeRequest(1200, 1000, 240)))
        // And a request the phone cannot apply at all changes nothing either.
        ledger.settle(ResizeRequest(1000, 1000, 300), ResizeOutcome.REFUSED)
        assertEquals(ResizeNeed.DENSITY, ledger.need(ResizeRequest(1000, 1000, 300)))
    }

    @Test
    fun `a density-only resize reports itself and keeps the size`() {
        val steps = Recorder()
        val current = IntSize(1600, 1200)
        val result = ResizeSequencer(steps).densityOnly(current, 360)

        assertEquals(ResizeSequencer.Outcome.DENSITY_ONLY, result.outcome)
        assertEquals(current, result.size)
        assertEquals(listOf("resizeDisplay 1600x1200@360"), steps.calls)
    }

    @Test
    fun `the wire names of the outcomes are the protocol's`() {
        assertEquals("resized", ResizeOutcome.RESIZED.wire)
        assertEquals("density", ResizeOutcome.DENSITY.wire)
        assertEquals("same", ResizeOutcome.SAME.wire)
        assertEquals("kept", ResizeOutcome.KEPT.wire)
        assertEquals("refused", ResizeOutcome.REFUSED.wire)
        assertTrue(ResizeLedger().remember(base).need(base) == ResizeNeed.SAME)
        assertFalse(ResizeLedger().remember(base).need(wider) == ResizeNeed.SAME)
    }

    private class Recorder : ResizeSteps {
        val calls = ArrayList<String>()
        /** The size the encoder takes, when the platform fits it. */
        var fitted: IntSize? = null

        override fun fit(w: Int, h: Int): IntSize = fitted ?: IntSize(w, h)

        override fun prepare(size: IntSize): IntSize? {
            calls += "prepare ${size.w}x${size.h}"
            return size
        }

        override fun resizeDisplay(size: IntSize, dpi: Int) {
            calls += "resizeDisplay ${size.w}x${size.h}@$dpi"
        }

        override fun attachPrepared(): Boolean {
            calls += "attach"
            return true
        }

        override fun releasePrevious() {
            calls += "releasePrevious"
        }
    }
}
