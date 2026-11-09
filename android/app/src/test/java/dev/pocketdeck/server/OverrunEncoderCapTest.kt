package dev.pocketdeck.server

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Emulator arm A at the queue/encoder level: a 1 Mbps target whose VBR encoder
 * puts out 16x the key (11.5 Mbps on the emulator) behind a link that carries
 * about 5 Mbps. The queue budget alone cannot fix this: it admits the whole key
 * frame, but the deltas behind it still outgrow the link, so the drop/key
 * cycle repeats. The cap on the key closes the loop on the measured output and
 * brings the codec down until its output fits the link.
 *
 * The queue, the bitrate policy and the cap are the real classes; the encoder,
 * the writer and the link are simulated on a virtual clock.
 */
class OverrunEncoderCapTest {

    private class Sim(
        private val linkBps: Int,
        private val targetBps: Int = 1_000_000,
        private val overshoot: Int = 16,
        private val vbrRatio: Double = 0.72,
        private val cap: EncoderCap? = null,
        private val seconds: Int = 120,
    ) {
        var nowUs = 0L
            private set
        var dropsAfter12s = 0
            private set
        var episodesAfter12s = 0
            private set
        var finalKeyBps = 0
            private set
        var finalOutputBps = 0
            private set
        private var keyPending = false
        private var busyUntilUs = 0L
        private var nextFrameUs = 0L
        private var nextPeriodicKeyUs = 10_000_000L
        private val quality = QualityAdaptation()
        private val samples = ArrayDeque<Pair<Long, Int>>()
        private val queue = SendQueue(
            maxDeltaBytesPerStream = 256 * 1024,
            maxDeltaDurationUs = 250_000,
            nowUs = { nowUs },
            nowMs = { nowUs / 1000 },
            linkBpsFor = { linkBps },
            onDeltaDrop = {
                val measured = encodedBps()
                if (nowUs / 1000 > 12_000) episodesAfter12s++
                quality.onDrop(nowUs / 1000, linkBps)
                cap?.onDrop(nowUs / 1000, linkBps, measured, keyBps())
                keyPending = true
            },
        )

        init {
            quality.setTarget(targetBps)
        }

        private fun keyBps(): Int {
            val key = (targetBps.toLong() * overshoot)
                .coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
            return minOf(key, cap?.capBps ?: Int.MAX_VALUE)
        }

        /** The encoder's own output, as the queue's GoodputMeter measures it. */
        private fun encodedBps(): Int? {
            val cutoff = nowUs - 1_000_000L
            while (samples.isNotEmpty() && samples.first().first < cutoff) samples.removeFirst()
            if (samples.isEmpty()) return null
            val span = nowUs - samples.first().first
            if (span < 50_000L) return null
            var bytes = 0L
            for ((_, n) in samples) bytes += n
            return (bytes * 8_000_000L / span).toInt()
        }

        fun run() {
            val endUs = seconds * 1_000_000L
            while (nowUs < endUs) {
                // 10 fps, the emulator's source rate; a key frame every 10 s
                // and one as soon as the queue asks.
                if (nowUs >= nextFrameUs) {
                    nextFrameUs += 100_000L
                    val key = keyPending || nowUs >= nextPeriodicKeyUs
                    if (nowUs >= nextPeriodicKeyUs) nextPeriodicKeyUs += 10_000_000L
                    val output = (keyBps().toLong() * vbrRatio).toInt()
                    val delta = (output / 8 / 10).coerceAtLeast(1)
                    val bytes = if (key) {
                        keyPending = false
                        delta * 10
                    } else {
                        delta
                    }
                    // The queue notes every encoded frame before it decides;
                    // the measured output includes this one.
                    samples.addLast(nowUs to bytes)
                    if (key) queue.enqueueControl(1, ByteArray(bytes), nowUs)
                    else queue.enqueueDelta(1, nowUs, ByteArray(bytes))
                    val stats = queue.takeDeltaStats(1)
                    if (nowUs / 1000 > 12_000) dropsAfter12s += stats.dropped
                }
                // The writer: one entry at a time, each taking its bytes at the
                // link's rate. This is the backlog the socket makes.
                if (nowUs >= busyUntilUs) {
                    val entry = queue.pollNow()
                    if (entry != null) {
                        busyUntilUs = nowUs + entry.bytes.size.toLong() * 8_000_000L / linkBps
                    }
                }
                quality.maybeRecover(nowUs / 1000)
                cap?.maybeProbe(nowUs / 1000)
                finalKeyBps = keyBps()
                finalOutputBps = (finalKeyBps.toLong() * vbrRatio).toInt()
                nowUs += 1_000L
            }
        }
    }

    @Test
    fun `without the cap the sixteen times key keeps the spiral`() {
        val sim = Sim(linkBps = 5_000_000)
        sim.run()
        assertTrue(
            "drop episodes after 12 s: ${sim.episodesAfter12s} " +
                "(${sim.dropsAfter12s} deltas dropped)",
            sim.episodesAfter12s > 1,
        )
    }

    @Test
    fun `the cap brings the encoder output under the link`() {
        val cap = EncoderCap()
        val sim = Sim(linkBps = 5_000_000, cap = cap)
        sim.run()
        assertTrue(
            "drop episodes after 12 s: ${sim.episodesAfter12s} " +
                "(${sim.dropsAfter12s} deltas dropped)",
            sim.episodesAfter12s <= 1,
        )
        assertTrue(
            "final encoder output ${sim.finalOutputBps / 1000} kbps on a " +
                "${sim.finalKeyBps / 1000} kbps key and a 5000 kbps link",
            sim.finalOutputBps <= 5_000_000,
        )
        assertTrue("the cap never moved", cap.capBps < Int.MAX_VALUE)
    }

    @Test
    fun `a steady three times overshoot settles within five seconds`() {
        val sim = Sim(
            linkBps = 30_000_000,
            targetBps = 8_000_000,
            overshoot = 1,
            vbrRatio = 3.0,
            cap = EncoderCap(),
            seconds = 10,
        )
        sim.run()
        val error = kotlin.math.abs(sim.finalOutputBps - 8_000_000).toDouble() / 8_000_000
        assertTrue(
            "key ${sim.finalKeyBps / 1000} kbps, output " +
                "${sim.finalOutputBps / 1000} kbps, believed 8000 kbps: error $error",
            error <= 0.15,
        )
    }
}
