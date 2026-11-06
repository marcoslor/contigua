package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** ISS-40 round 3: an episode's own count and clock, from the drop to the key. */
class DropRecoveryTest {

    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { v[it].toByte() }

    private fun delta(): ByteArray = bytes(0, 0, 1, 0x41, 0x11)

    /** SPS (7), PPS (8), IDR slice (5): a key frame the decoder can start on. */
    private val idr = bytes(0, 0, 0, 1, 0x67, 1, 0, 0, 1, 0x68, 2, 0, 0, 0, 1, 0x65, 3)

    /** SEI (6), non-IDR slice (1): flagged key, not an IDR (intra refresh). */
    private val nonIdrKey = bytes(0, 0, 1, 0x06, 9, 0, 0, 1, 0x41, 4)

    /** A drop episode: sent baseline, one queued delta, then four discarded. */
    private fun droppedQueue(lines: MutableList<String>, now: () -> Long): SendQueue {
        val queue = SendQueue(nowMs = now, log = { lines += it })
        queue.enqueueDelta(3, 0, delta())
        queue.pollNow()
        queue.enqueueDelta(3, 16_667, delta())
        // 483 ms of video queued against a 250 ms budget: the episode begins.
        queue.enqueueDelta(3, 500_000, delta())
        repeat(3) { queue.enqueueDelta(3, 516_667, delta()) }
        return queue
    }

    @Test
    fun aDropEpisodeEndsWithTheKeyFrameAndItsDelay() {
        val lines = mutableListOf<String>()
        var nowMs = 1_000L
        val queue = droppedQueue(lines) { nowMs }
        nowMs = 1_712
        queue.enqueueControl(3, idr, 533_334)
        queue.pollNow()
        assertEquals(
            "stream 3 drop: 5 dropped, key after 712 ms, nal=7,8,5",
            lines.last(),
        )
        assertTrue(lines.contains("stream 3 drop episode: flowing --dropped(2)--> waiting"))
        assertTrue(lines.contains("stream 3 drop episode: waiting --key--> flowing"))
    }

    @Test
    fun aKeyFrameWithNoIdrNamesTheTypesThatResumedThePicture() {
        val lines = mutableListOf<String>()
        var nowMs = 1_000L
        val queue = droppedQueue(lines) { nowMs }
        nowMs = 1_250
        queue.enqueueControl(3, nonIdrKey, 533_334)
        queue.pollNow()
        assertEquals(
            "stream 3 drop: 5 dropped, key after 250 ms, nal=6,1",
            lines.last(),
        )
    }

    @Test
    fun aKeyFrameWhileFlowingLogsNoDropLine() {
        val lines = mutableListOf<String>()
        val queue = SendQueue(nowMs = { 0L }, log = { lines += it })
        queue.enqueueControl(3, idr, 0)
        queue.pollNow()
        assertFalse(lines.any { it.startsWith("stream 3 drop:") })
    }

    @Test
    fun aSecondEpisodeCountsItsOwnDeltasAndStartsItsOwnClock() {
        val lines = mutableListOf<String>()
        var nowMs = 1_000L
        val queue = SendQueue(nowMs = { nowMs }, log = { lines += it })
        queue.enqueueDelta(3, 0, delta())
        queue.pollNow()
        queue.enqueueDelta(3, 16_667, delta())
        queue.enqueueDelta(3, 500_000, delta())
        nowMs = 1_100
        queue.enqueueControl(3, idr, 516_667)
        queue.pollNow()
        assertEquals("stream 3 drop: 2 dropped, key after 100 ms, nal=7,8,5", lines.last())

        nowMs = 2_000
        queue.enqueueDelta(3, 1_000_000, delta())
        queue.enqueueDelta(3, 1_500_000, delta())
        nowMs = 2_500
        queue.enqueueControl(3, idr, 1_516_667)
        queue.pollNow()
        assertEquals("stream 3 drop: 2 dropped, key after 500 ms, nal=7,8,5", lines.last())
    }
}
