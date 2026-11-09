package dev.pocketdeck.server

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Overrun at the queue/encoder level, with the inner loop on the encoder's
 * measured output.
 *
 * Arm A: a 16 Mbps key on a 1 Mbps target and a VBR encoder that puts out 72%
 * of the key, on a link carrying about 5 Mbps. Arm B: a 1 Mbps key putting out
 * 1.3 Mbps on a 1.10 Mbps writer goodput. Without the correction both keep the
 * drop/keyframe spiral; with it the key follows the believed bitrate.
 *
 * The queue, the bitrate policy and the correction are the real classes; the
 * encoder, the writer and the link are simulated on a virtual clock.
 */
class OverrunEncoderLoopTest {

    private class Sim(
        private val linkBps: Int,
        private val targetBps: Int = 1_000_000,
        private val overshoot: Int = 16,
        private val vbrRatio: Double = 0.72,
        private val correction: EncoderCorrection? = null,
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
        private val deltaSamples = ArrayDeque<Pair<Long, Int>>()
        private val queue = SendQueue(
            maxDeltaBytesPerStream = 256 * 1024,
            maxDeltaDurationUs = 250_000,
            nowUs = { nowUs },
            nowMs = { nowUs / 1000 },
            linkBpsFor = { linkBps },
            onDeltaDrop = {
                val measured = encodedBps()
                if (nowUs / 1000 > 12_000) episodesAfter12s++
                val keyBefore = keyBps()
                quality.onDrop(nowUs / 1000, linkBps)
                correction?.sample(nowUs / 1000, measured, keyBefore)
                keyPending = true
            },
        )

        init {
            quality.setTarget(targetBps)
        }

        private fun uncorrectedBps(): Int =
            (targetBps.toLong() * overshoot)
                .coerceAtMost(Int.MAX_VALUE.toLong()).toInt()

        private fun keyBps(): Int =
            correction?.keyFor(nowUs / 1000, quality.bitrate, uncorrectedBps())
                ?: uncorrectedBps()

        /** The encoder's output as the queue's GoodputMeter sees it (keys included). */
        private fun encodedBps(): Int? = rate(samples)

        /** Delta output only: what the correction's one-second meter reads. */
        private fun deltaBps(): Int? = rate(deltaSamples)

        private fun rate(source: ArrayDeque<Pair<Long, Int>>): Int? {
            val cutoff = nowUs - 1_000_000L
            while (source.isNotEmpty() && source.first().first < cutoff) source.removeFirst()
            if (source.isEmpty()) return null
            val span = nowUs - source.first().first
            if (span < 50_000L) return null
            var bytes = 0L
            for ((_, n) in source) bytes += n
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
                    if (!key) deltaSamples.addLast(nowUs to bytes)
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
                if (correction != null && nowUs % 1_000_000L == 0L) {
                    correction.sample(nowUs / 1000, deltaBps(), keyBps())
                }
                finalKeyBps = keyBps()
                finalOutputBps = (finalKeyBps.toLong() * vbrRatio).toInt()
                nowUs += 1_000L
            }
        }
    }

    @Test
    fun `without the correction the sixteen times key keeps the spiral`() {
        val sim = Sim(linkBps = 5_000_000)
        sim.run()
        assertTrue(
            "drop episodes after 12 s: ${sim.episodesAfter12s} " +
                "(${sim.dropsAfter12s} deltas dropped)",
            sim.episodesAfter12s > 1,
        )
    }

    @Test
    fun `the correction brings the encoder output under the link`() {
        val correction = EncoderCorrection()
        val sim = Sim(linkBps = 5_000_000, correction = correction)
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
        assertTrue(
            "the correction never moved",
            correction.state != EncoderCorrection.State.Unmeasured,
        )
    }

    @Test
    fun `the correction brings arm B's encoder output under the link`() {
        val correction = EncoderCorrection()
        val sim = Sim(
            linkBps = 1_100_000,
            targetBps = 1_000_000,
            overshoot = 1,
            vbrRatio = 1.3,
            correction = correction,
        )
        sim.run()
        // The average output follows the believed bitrate; the periodic key
        // frame is still a burst the link must carry (the I-frame question).
        assertTrue(
            "final encoder output ${sim.finalOutputBps / 1000} kbps on a " +
                "${sim.finalKeyBps / 1000} kbps key and a 1100 kbps link",
            sim.finalOutputBps <= 1_100_000,
        )
        assertTrue("the key ${sim.finalKeyBps} was not brought under the target", sim.finalKeyBps < 1_000_000)
    }

    @Test
    fun `a steady three times overshoot settles within five seconds`() {
        val correction = EncoderCorrection()
        val sim = Sim(
            linkBps = 30_000_000,
            targetBps = 8_000_000,
            overshoot = 1,
            vbrRatio = 3.0,
            correction = correction,
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
