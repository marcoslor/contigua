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
    fun theTotalsLineCoversTheStreamsWholeLife() {
        val stats = StreamStats()
        stats.onFrame(key = true, bytes = 1_000, encodeUs = 5_000, qpValue = 20)
        stats.onFrame(key = false, bytes = 500, encodeUs = 9_000, qpValue = 30)
        stats.onSkipped()
        stats.onSkipped()
        // The 2 s windows reset; the closing totals do not.
        stats.snapshot(reset = true)
        stats.onFrame(key = false, bytes = 250, encodeUs = 2_000, qpValue = null)
        assertEquals(
            "stream 7 totals: out=3 sent=3 skipped=2 bytes=1750 susp_ms=0 key_idr=0 key_not_idr=0 secs=4.2 codec=avc qp_avg=25.0",
            stats.totalsLine(stream = 7, secs = 4.2),
        )
        assertEquals(
            "reading the line does not consume the lifetime counters",
            "stream 7 totals: out=3 sent=3 skipped=2 bytes=1750 susp_ms=0 key_idr=0 key_not_idr=0 secs=4.2 codec=avc qp_avg=25.0",
            stats.totalsLine(stream = 7, secs = 4.2),
        )
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
        val send = SendSnapshot(5, 3, 700, 1_100, dropGapMs = 480)
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
        assertEquals(480L, message["dropGapMs"])
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
        assertEquals(0L, message["keyIdr"])
        assertEquals(0L, message["keyNotIdr"])
    }

    @Test
    fun theWireMessageCarriesTheKeyCounts() {
        val encoder = EncoderStats(
            frames = 60, keyframes = 3, keyframesRequested = 2, bytes = 1,
            framesSkipped = 0, targetBps = 6_000_000,
            encodeP50 = null, encodeP95 = null, qpP50 = null, qpP95 = null,
            keyIdr = 2, keyNotIdr = 1,
        )
        val message = StreamStatsWire.message(7, 2_000, encoder, SendSnapshot(0, 0, null, null))
        assertEquals(2L, message["keyIdr"])
        assertEquals(1L, message["keyNotIdr"])
    }

    @Test
    fun suspendAndRefineCountersAccumulatePerWindow() {
        var now = 1_000L
        val stats = StreamStats { now }
        stats.onSuspendStart(now)
        stats.onSuspendStart(now + 100) // the same episode's rising edge only
        now = 4_000
        stats.onSuspendEnd(now)
        stats.onRefined()
        val first = stats.snapshot()
        assertEquals(1L, first.suspendedEpisodes)
        assertEquals(3_000L, first.suspendedMs)
        assertEquals(1L, first.refined)

        // An open episode counts what it has run, and the next window carries
        // on from there: no span is reported twice.
        stats.onSuspendStart(5_000)
        now = 5_500
        val open = stats.snapshot()
        assertEquals(1L, open.suspendedEpisodes)
        assertEquals(500L, open.suspendedMs)
        now = 6_000
        stats.onSuspendEnd(now)
        assertEquals(500L, stats.snapshot().suspendedMs)
    }

    @Test
    fun anOpenSuspendEpisodeIsCountedInEverySnapshotWithoutDoubleCounting() {
        val stats = StreamStats()
        stats.onSuspendStart(1_000)
        assertEquals(1_500L, stats.snapshot(nowMs = 2_500).suspendedMs)
        assertEquals(500L, stats.snapshot(nowMs = 3_000).suspendedMs)
        stats.onSuspendEnd(4_000)
        assertEquals(1_000L, stats.snapshot(nowMs = 9_000).suspendedMs)
    }

    @Test
    fun theTotalsLineCarriesAnOpenSuspendEpisode() {
        val stats = StreamStats()
        stats.onSuspendStart(1_000)
        // A snapshot reported the first 1500 ms; the closing line still
        // carries the episode whole, from its own start.
        assertEquals(1_500L, stats.snapshot(nowMs = 2_500).suspendedMs)
        assertEquals(
            "stream 7 totals: out=0 sent=0 skipped=0 bytes=0 susp_ms=2000 key_idr=0 key_not_idr=0 secs=3.0 codec=avc qp_avg=-",
            stats.totalsLine(stream = 7, secs = 3.0, nowMs = 3_000),
        )
    }

    @Test
    fun keyFlaggedFramesAreCountedByWhetherTheyHoldAnIdr() {
        val lines = mutableListOf<String>()
        val stats = StreamStats(stream = 4, log = { lines += it })
        stats.onFrame(key = true, bytes = 10, encodeUs = null, qpValue = null,
                      keyNalTypes = listOf(7, 8, 5))
        repeat(5) {
            stats.onFrame(key = true, bytes = 10, encodeUs = null, qpValue = null,
                          keyNalTypes = listOf(6, 1))
        }
        stats.onFrame(key = false, bytes = 10, encodeUs = null, qpValue = null,
                      keyNalTypes = listOf(1))
        val first = stats.snapshot()
        assertEquals(1L, first.keyIdr)
        assertEquals(5L, first.keyNotIdr)
        assertEquals("only the first 3 non-IDR key frames are logged", 3, lines.size)
        assertTrue(lines.all { it == "stream 4 key nal=6,1" })
        // The window resets; the lifetime counts and the log cap do not.
        val second = stats.snapshot()
        assertEquals(0L, second.keyIdr)
        assertEquals(0L, second.keyNotIdr)
        stats.onFrame(key = true, bytes = 10, encodeUs = null, qpValue = null,
                      keyNalTypes = listOf(6, 1))
        assertEquals(1L, stats.snapshot().keyNotIdr)
        assertEquals(3, lines.size)
    }

    @Test
    fun theTotalsLineCarriesTheIdrAndNonIdrKeyCounts() {
        val stats = StreamStats()
        stats.onFrame(key = true, bytes = 1, encodeUs = null, qpValue = null,
                      keyNalTypes = listOf(7, 8, 5))
        stats.onFrame(key = true, bytes = 1, encodeUs = null, qpValue = null,
                      keyNalTypes = listOf(6, 1))
        val line = stats.totalsLine(stream = 7, secs = 4.2)
        assertTrue(line, line.contains("out=2"))
        assertTrue(line, line.contains("key_idr=1 key_not_idr=1"))
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
    fun qpAvgIsTheMeanOfTheWindowsFrameAverages() {
        val stats = StreamStats()
        stats.onFrame(key = false, bytes = 1, encodeUs = null, qpValue = 20)
        stats.onFrame(key = false, bytes = 1, encodeUs = null, qpValue = 30)
        stats.onFrame(key = false, bytes = 1, encodeUs = null, qpValue = null)
        assertEquals(25.0, stats.snapshot().qpAvg!!, 0.001)
        // A window with no QP has no mean; the lifetime mean still covers the
        // frames that reported one.
        assertNull(stats.snapshot().qpAvg)
        val line = stats.totalsLine(stream = 7, secs = 4.2)
        assertTrue(line, line.contains(" qp_avg=25.0"))
    }

    @Test
    fun aHevcCraIsAKeyFrameWithoutAnIdr() {
        val stats = StreamStats()
        stats.codec = VideoCodec.Hevc
        stats.onFrame(key = true, bytes = 10, encodeUs = null, qpValue = null,
                      keyNalTypes = listOf(32, 33, 34, 19))
        stats.onFrame(key = true, bytes = 10, encodeUs = null, qpValue = null,
                      keyNalTypes = listOf(32, 33, 34, 21))
        stats.onFrame(key = false, bytes = 10, encodeUs = null, qpValue = null,
                      keyNalTypes = listOf(1))
        val window = stats.snapshot()
        assertEquals(1L, window.keyIdr)
        assertEquals(1L, window.keyNotIdr)
        assertEquals(VideoCodec.Hevc, window.codec)
        assertTrue(stats.totalsLine(stream = 7, secs = 4.2).contains("codec=hevc"))
    }

    @Test
    fun theWireMessageCarriesTheCodecOnceAndTheQpMean() {
        val stats = StreamStats()
        stats.codec = VideoCodec.Hevc
        stats.onFrame(key = false, bytes = 10, encodeUs = null, qpValue = 24)
        val encoder = stats.snapshot()
        val message = StreamStatsWire.message(7, 2_000, encoder, SendSnapshot(0, 0, null, null))
        assertEquals("hevc", message["codec"])
        assertEquals(24.0, message["qpAvg"])
    }

    @Test
    fun sendStatsResetsQueueDelaysPerWindowAndSkipsAbsurdOnes() {
        val send = SendStats()
        send.onWritten(500)
        send.onWritten(1_500)
        send.onWritten(30_000_001) // a stalled clock, not a delay
        val first = send.snapshot(deltasDropped = 7, dropEpisodes = 2, dropGapMs = 480)
        assertEquals(7, first.deltasDropped)
        assertEquals(2, first.dropEpisodes)
        assertEquals(480L, first.dropGapMs)
        assertEquals(500L, first.queueP50)
        assertEquals(1_500L, first.queueP95)
        val second = send.snapshot(0, 0)
        assertNull(second.queueP50)
        assertEquals(0L, second.dropGapMs)
    }
}
