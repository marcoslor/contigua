package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ISS-40's QP sample: once per stream, after the 30th output buffer, the last
 * 10 raw values the codec reported and the output format's own QP key names.
 * The reviewer reads the line on the real phone, where the stats counters said
 * a QP of 1-2 at a scrolling bitrate that should not allow it.
 */
class QpSampleProbeTest {

    @Test
    fun `nothing is logged before the thirtieth output buffer`() {
        val probe = QpSampleProbe()
        for (index in 1 until 30) {
            assertFalse("buffer $index must not log", probe.note(index))
        }
    }

    @Test
    fun `the thirtieth buffer logs the last ten raw values once`() {
        val probe = QpSampleProbe()
        var logged = false
        for (index in 1..30) {
            logged = probe.note(index)
            assertEquals("only the 30th buffer logs", index == 30, logged)
        }
        val line = probe.line(stream = 3,
                              formatKeys = setOf("video-qp-average", "mime", "width"))
        assertEquals("stream 3 qp sample: key=video-qp-average values=21,22,23,24,25,26,27,28,29,30 qp_keys=video-qp-average", line)
        assertFalse("a stream samples once", probe.note(31))
    }

    @Test
    fun `a codec without QP still logs the sample line with no values`() {
        val probe = QpSampleProbe()
        var logged = false
        for (index in 1..30) logged = probe.note(null)
        assertTrue("the thirtieth buffer logs even with no QP", logged)
        val line = probe.line(stream = 1, formatKeys = setOf("mime", "width"))
        assertEquals("stream 1 qp sample: key=video-qp-average values=- qp_keys=-", line)
    }

    @Test
    fun `only the output format key names that contain qp are listed`() {
        val probe = QpSampleProbe()
        for (index in 1..30) probe.note(20)
        val line = probe.line(stream = 2,
                              formatKeys = setOf("video-qp-average", "QP-Something",
                                                 "mime", "csd-0", "qp"))
        assertTrue(line, line.endsWith("qp_keys=QP-Something,qp,video-qp-average"))
    }
}
