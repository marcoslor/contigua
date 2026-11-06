package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * P3's shipped media default (docs/specs/transport.md PATH-25): the transport
 * is TCP until P5, it prints nothing in the strategy line, and only the bench
 * turns the UDP machine on. This is the test the review asked for — the
 * default is not a comment.
 */
class MediaDefaultsTest {

    @Test
    fun `the shipped media transport is tcp and prints nothing`() {
        assertEquals(StreamStrategy.Transport.Tcp, StreamStrategy.DEFAULT.transport)
        assertEquals("default", StreamStrategy.DEFAULT.describe())
        assertTrue(StreamStrategy.DEFAULT.isDefault)
    }

    @Test
    fun `auto and udp parse and print their closed tokens`() {
        val auto = StreamStrategy.parse { if (it == "transport") "auto" else null }
        assertEquals(StreamStrategy.Transport.Auto, auto.transport)
        assertEquals("transport=auto", auto.describe())
        assertFalse(auto.isDefault)

        val udp = StreamStrategy.parse { if (it == "transport") "udp" else null }
        assertEquals(StreamStrategy.Transport.Udp, udp.transport)
        assertEquals("transport=udp", udp.describe())
    }

    @Test
    fun `junk stays on tcp`() {
        assertEquals(StreamStrategy.Transport.Tcp,
            StreamStrategy.parse { if (it == "transport") "quick" else null }.transport)
        assertEquals(StreamStrategy.Transport.Tcp,
            StreamStrategy.parse { if (it == "transport") "" else null }.transport)
    }
}
