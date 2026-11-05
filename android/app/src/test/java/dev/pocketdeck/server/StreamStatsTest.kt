package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** ISS-40's phone counters: plain increments, ring percentiles and the wire shape. */
class StreamStatsTest {

    @Test
    fun countersAndTargetAccumulateAndReset() {
        val stats = StreamStats()
        stats.setTarget(8_000_000)
        stats.onFrame(key = true, bytes = 1_000, encodeUs = 5_000, qpValue = 20)
        stats.onFrame(key = false, bytes = 500, encodeUs = 9_000, qpValue = 30)
        stats.onFrame(key = false, bytes = 500, encodeUs = null, qpValue = null)
        stats.onKeyframeRequested()
        stats.onSkipped()

        val first = stats.snapshot()
        assertEquals(3L, first.frames)
        assertEquals(1L, first.keyframes)
        assertEquals(1L, first.keyframesRequested)
        assertEquals(2_000L, first.bytes)
        assertEquals(1L, first.framesSkipped)
        assertEquals(8_000_000, first.targetBps)
        assertEquals(5_000L, first.encodeP50)
        assertEquals(9_000L, first.encodeP95)
        assertEquals(20, first.qpP50)
        assertEquals(30, first.qpP95)

        val second = stats.snapshot()
        assertEquals(0L, second.frames)
        assertEquals(0L, second.bytes)
        assertEquals(0L, second.framesSkipped)
        assertNull(second.encodeP50)
        assertNull(second.qpP95)
        // The target is a live value, not a window counter.
        assertEquals(8_000_000, second.targetBps)
    }

    @Test
    fun anImpossibleEncodeDelayIsNotASample() {
        val stats = StreamStats()
        stats.onFrame(key = false, bytes = 1, encodeUs = -1, qpValue = null)
        stats.onFrame(key = false, bytes = 1, encodeUs = 11_000_000, qpValue = null)
        assertNull(stats.snapshot().encodeP50)
    }

    @Test
    fun percentilesUseNearestRank() {
        val ring = LongRing(100)
        for (value in 1..100) ring.add(value.toLong())
        assertEquals(50L, ring.percentile(0.50))
        assertEquals(95L, ring.percentile(0.95))
        ring.clear()
        assertNull(ring.percentile(0.50))
    }

    @Test
    fun aFullRingKeepsTheNewestSamples() {
        val ring = LongRing(4)
        for (value in 1..6) ring.add(value.toLong())
        assertEquals(3L, ring.percentile(0.0)) // 3,4,5,6 sorted
        assertEquals(6L, ring.percentile(1.0))
        val qp = IntRing(3)
        for (value in listOf(10, 20, 30, 40)) qp.add(value)
        assertEquals(20, qp.percentile(0.0))
        assertNull(IntRing(1).percentile(0.5))
    }

    @Test
    fun theWireMessageCarriesEveryCounterAndOmitsMissingMeasurements() {
        val encoder = EncoderStats(
            frames = 60, keyframes = 1, keyframesRequested = 2, bytes = 123_456,
            framesSkipped = 4, targetBps = 6_000_000,
            encodeP50 = 8_000, encodeP95 = 12_000, qpP50 = null, qpP95 = null,
        )
        val send = SendSnapshot(5, 3, 700, 1_100)
        val message = StreamStatsWire.message(7, 2_000, encoder, send)
        assertEquals("stream.stats", message["t"])
        assertEquals(7, message["stream"])
        assertEquals(2_000L, message["windowMs"])
        assertEquals(60L, message["frames"])
        assertEquals(1L, message["kf"])
        assertEquals(2L, message["kfReq"])
        assertEquals(123_456L, message["bytes"])
        assertEquals(5, message["drop"])
        assertEquals(3, message["dropEp"])
        assertEquals(4L, message["skip"])
        assertEquals(6_000_000, message["targetBps"])
        assertEquals(8_000L, message["encP50"])
        assertEquals(12_000L, message["encP95"])
        assertEquals(700L, message["queueP50"])
        assertEquals(1_100L, message["queueP95"])
        assertFalse(message.containsKey("qpP50"))
        assertFalse(message.containsKey("qpP95"))
        // Q1/T1 counters ride every message, zero when nothing happened.
        assertEquals(0L, message["susp"])
        assertEquals(0L, message["suspMs"])
        assertEquals(0L, message["refine"])
    }

    @Test
    fun suspendAndRefineCountersAccumulatePerWindow() {
        val stats = StreamStats()
        stats.onSuspendStart(1_000)
        stats.onSuspendStart(1_100) // the same episode's rising edge only
        stats.onSuspendEnd(4_000)
        stats.onRefined()
        val first = stats.snapshot()
        assertEquals(1L, first.suspendedEpisodes)
        assertEquals(3_000L, first.suspendedMs)
        assertEquals(1L, first.refined)

        // An episode that ends in a later window lands there whole, once.
        stats.onSuspendStart(5_000)
        assertEquals(1L, stats.snapshot().suspendedEpisodes)
        assertEquals(0L, stats.snapshot().suspendedMs)
        stats.onSuspendEnd(6_000)
        assertEquals(1_000L, stats.snapshot().suspendedMs)
    }

    @Test
    fun qpIsPresentOnlyWhenTheCodecReportsIt() {
        val encoder = EncoderStats(1, 0, 0, 1, 0, 0, null, null, 24, 31)
        val message = StreamStatsWire.message(1, 2_000, encoder, SendSnapshot(0, 0, null, null))
        assertEquals(24, message["qpP50"])
        assertEquals(31, message["qpP95"])
        assertTrue(message.containsKey("targetBps"))
    }

    @Test
    fun sendStatsResetsQueueDelaysPerWindowAndSkipsAbsurdOnes() {
        val send = SendStats()
        send.onWritten(500)
        send.onWritten(1_500)
        send.onWritten(30_000_001) // a stalled clock, not a delay
        val first = send.snapshot(deltasDropped = 7, dropEpisodes = 2)
        assertEquals(7, first.deltasDropped)
        assertEquals(2, first.dropEpisodes)
        assertEquals(500L, first.queueP50)
        assertEquals(1_500L, first.queueP95)
        val second = send.snapshot(0, 0)
        assertNull(second.queueP50)
    }
}
