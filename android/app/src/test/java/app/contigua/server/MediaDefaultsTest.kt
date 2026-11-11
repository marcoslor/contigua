package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The media plane is TCP only (docs/specs/transport.md, PATH-25..35 withdrawn
 * 2026-11-09 after the losslab probe). A leftover `transport` bench property
 * from the planned UDP plane must change nothing.
 */
class MediaDefaultsTest {

    @Test
    fun `the shipped strategy prints nothing`() {
        assertEquals("default", StreamStrategy.DEFAULT.describe())
        assertTrue(StreamStrategy.DEFAULT.isDefault)
    }

    @Test
    fun `a leftover transport property is ignored`() {
        for (value in listOf("udp", "auto", "tcp", "quick", "")) {
            val parsed = StreamStrategy.parse { if (it == "transport") value else null }
            assertEquals(StreamStrategy.DEFAULT, parsed)
            assertEquals("default", parsed.describe())
        }
    }
}
