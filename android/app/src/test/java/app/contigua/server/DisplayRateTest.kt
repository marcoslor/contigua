package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * WIN-61's display-rate decision: 0/junk is off, a positive value clamps to
 * 60–120 Hz, and a builder without `setRequestedRefreshRate` gets null plus the
 * closed fallback token. Pure Kotlin, so the reflection below is injected.
 */
class DisplayRateTest {

    @Test
    fun `zero and junk request no rate`() {
        assertNull(DisplayRate.requested(0, builderHasMethod = true))
        assertNull(DisplayRate.requested(-5, builderHasMethod = true))
        assertNull(DisplayRate.requested(0, builderHasMethod = false))
    }

    @Test
    fun `60 90 and 120 request that float`() {
        assertEquals(60f, DisplayRate.requested(60, builderHasMethod = true))
        assertEquals(90f, DisplayRate.requested(90, builderHasMethod = true))
        assertEquals(120f, DisplayRate.requested(120, builderHasMethod = true))
    }

    @Test
    fun `a positive value clamps to 60-120`() {
        assertEquals(60f, DisplayRate.requested(30, builderHasMethod = true))
        assertEquals(60f, DisplayRate.requested(1, builderHasMethod = true))
        assertEquals(120f, DisplayRate.requested(200, builderHasMethod = true))
    }

    @Test
    fun `a builder without the method requests nothing and names the fallback`() {
        assertNull(DisplayRate.requested(120, builderHasMethod = false))
        assertEquals("vd_rate=120 unsupported",
                     DisplayRate.unsupported(120, builderHasMethod = false))
        assertNull(DisplayRate.unsupported(120, builderHasMethod = true))
        assertNull(DisplayRate.unsupported(0, builderHasMethod = false))
    }

    @Test
    fun `the classic path names the rate it cannot request`() {
        assertEquals("rate=120 unsupported (classic)", DisplayRate.classicUnsupported(120))
        assertEquals("rate=60 unsupported (classic)", DisplayRate.classicUnsupported(30))
        assertNull(DisplayRate.classicUnsupported(0))
    }

    @Test
    fun `the display line names an applied rate`() {
        assertEquals("rate=90", DisplayRate.displayToken(90f))
        assertEquals("rate=120", DisplayRate.displayToken(120f))
        assertNull(DisplayRate.displayToken(null))
    }
}
