package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Overrun arm A at the queue/adaptation level: an encoder whose real output is
 * 3x the 8 Mbps target, on a 30 Mbps path. A key frame is 10 deltas' worth
 * (about a second of video at the target), which is larger than the queue's
 * 256 KB byte budget (250 ms at the believed 8 Mbps, 68 ms at the path's real
 * rate). The queue drops the deltas behind the key frame and asks for another
 * key frame; that key frame overflows the queue again, and the drop/key-frame
 * cycle repeats even though the link carries every byte.
 *
 * The queue and the bitrate policy are the real classes; only the encoder, the
 * writer and the link are simulated, on a virtual clock, so the test is exact
 * and fast. It is the item-1 repro: it fails on the pre-fix code.
 */
class OverrunSpiralTest {

    private class Sim(
        private val linkBps: Int,
        private val overshoot: Int,
        private val seconds: Int = 120,
    ) {
        var nowUs = 0L
            private set
        val dropAtMs = ArrayList<Long>()
        var droppedAfter12s = 0
            private set
        var minBitrate = Int.MAX_VALUE
            private set
        private var keyPending = false
        private var busyUntilUs = 0L
        private var nextFrameUs = 0L
        private var nextPeriodicKeyUs = 10_000_000L
        private val quality = QualityAdaptation()
        private val queue = SendQueue(
            maxDeltaBytesPerStream = 256 * 1024,
            maxDeltaDurationUs = 250_000,
            nowUs = { nowUs },
            nowMs = { nowUs / 1000 },
            onDeltaDrop = {
                dropAtMs.add(nowUs / 1000)
                quality.onDrop(nowUs / 1000, null)
                keyPending = true
            },
        )

        init {
            quality.setTarget(8_000_000)
        }

        private fun deltaBytes(): Int =
            (quality.bitrate.toLong() / 8 / 60 * overshoot).toInt().coerceAtLeast(1)

        private fun keyBytes(): Int = deltaBytes() * 10

        fun run() {
            val endUs = seconds * 1_000_000L
            while (nowUs < endUs) {
                // The encoder: 60 fps, a periodic key frame every 10 s, and one
                // as soon as the queue asks for it.
                if (nowUs >= nextFrameUs) {
                    nextFrameUs += 16_667L
                    val key = keyPending || nowUs >= nextPeriodicKeyUs
                    if (nowUs >= nextPeriodicKeyUs) nextPeriodicKeyUs += 10_000_000L
                    if (key) {
                        keyPending = false
                        queue.enqueueControl(1, ByteArray(keyBytes()), nowUs)
                    } else {
                        queue.enqueueDelta(1, nowUs, ByteArray(deltaBytes()))
                    }
                    val stats = queue.takeDeltaStats(1)
                    if (nowUs / 1000 > 12_000) droppedAfter12s += stats.dropped
                }
                // The writer: one entry at a time, each taking its bytes at the
                // path's real rate. This is the same backlog the socket makes.
                if (nowUs >= busyUntilUs) {
                    val entry = queue.pollNow()
                    if (entry != null) {
                        busyUntilUs = nowUs + entry.bytes.size.toLong() * 8_000_000L / linkBps
                    }
                }
                quality.maybeRecover(nowUs / 1000)
                minBitrate = minOf(minBitrate, quality.bitrate)
                nowUs += 1_000L
            }
        }

        fun episodesAfter12s(): Int = dropAtMs.count { it > 12_000 }
    }

    @Test
    fun aKeyframeLargerThanTheBudgetMustNotStartAKeyframeCycle() {
        val sim = Sim(linkBps = 30_000_000, overshoot = 3)
        sim.run()
        val episodes = sim.episodesAfter12s()
        assertTrue(
            "drop episodes after 12 s: $episodes (${sim.dropAtMs.size} in 120 s); " +
                "lowest bitrate ${sim.minBitrate / 1000} kbps",
            episodes <= 1,
        )
        assertEquals(
            "deltas dropped after 12 s; lowest bitrate ${sim.minBitrate / 1000} kbps",
            0,
            sim.droppedAfter12s,
        )
        assertTrue(
            "the bitrate collapsed to ${sim.minBitrate / 1000} kbps: the queue " +
                "budget, not the link, was the limit",
            sim.minBitrate >= 6_000_000,
        )
    }
}
