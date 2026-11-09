package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * The overrun fix at the queue level: the byte budget is 250 ms at the
 * *measured* rate (the link's goodput when the writer has a sample, else the
 * encoder's own output), plus the key frame's own bytes, and the duration
 * budget carries the key frame's send time. A key frame or a burst that is
 * larger than the believed-target 256 KB is admitted; a genuinely slow link
 * still drops.
 */
class SendQueueBudgetTest {

    private var nowUs = 0L
    private val frameUs = 16_667L

    private fun queue(
        linkBps: Int? = null,
        drops: AtomicInteger = AtomicInteger(),
    ): SendQueue = SendQueue(
        maxDeltaBytesPerStream = 256 * 1024,
        maxDeltaDurationUs = 250_000,
        nowUs = { nowUs },
        onDeltaDrop = { drops.incrementAndGet() },
        linkBpsFor = { linkBps },
    )

    @Test
    fun `a burst over the believed byte budget is admitted at the measured rate`() {
        val drops = AtomicInteger()
        val q = queue(linkBps = 30_000_000, drops = drops)
        // 8 x 50 KB = 400 KB in 133 ms: 250 ms at 30 Mbps is 937 KB.
        repeat(8) {
            nowUs += frameUs
            q.enqueueDelta(1, nowUs, ByteArray(50_000))
        }
        assertEquals("no delta dropped", 0, drops.get())
        var sent = 0
        while (q.pollNow() != null) sent++
        assertEquals(8, sent)
    }

    @Test
    fun `a key frame bigger than the believed budget is admitted`() {
        val drops = AtomicInteger()
        val q = queue(linkBps = 30_000_000, drops = drops)
        nowUs += frameUs
        q.enqueueControl(1, ByteArray(600_000), nowUs)
        // The deltas that arrive while the key frame is written fit too.
        repeat(8) {
            nowUs += frameUs
            q.enqueueDelta(1, nowUs, ByteArray(50_000))
        }
        assertEquals("no drop with a 600 KB key frame", 0, drops.get())
        val first = q.pollNow()!!
        assertTrue("the key frame is first", first.key)
        assertEquals(600_000, first.bytes.size)
    }

    @Test
    fun `the deltas behind a long key frame are not dropped`() {
        val drops = AtomicInteger()
        val q = queue(linkBps = 30_000_000, drops = drops)
        // A 600 KB key frame at 30 Mbps takes 160 ms; the deltas behind it
        // span 300 ms, over the base 250 ms duration budget.
        nowUs += frameUs
        q.enqueueControl(1, ByteArray(600_000), nowUs)
        repeat(18) {
            nowUs += frameUs
            q.enqueueDelta(1, nowUs, ByteArray(50_000))
        }
        assertEquals("no drop behind the key frame", 0, drops.get())
    }

    @Test
    fun `a sent key frame's bytes still cover the deltas behind it`() {
        val drops = AtomicInteger()
        val q = queue(linkBps = 3_000_000, drops = drops)
        // A 600 KB key frame at 3 Mbps takes 1.6 s; 96 x 6 KB deltas arrive
        // behind it (the encoder's output is the link's rate).
        nowUs += frameUs
        q.enqueueControl(1, ByteArray(600_000), nowUs)
        repeat(96) {
            nowUs += frameUs
            q.enqueueDelta(1, nowUs, ByteArray(6_000))
        }
        assertEquals("the key frame's bytes admit its own send window", 0, drops.get())
        val key = q.pollNow()!!
        assertTrue("the key frame is first", key.key)
        // The key is on the socket now. The queued deltas were admitted
        // against its bytes, so a few more that arrive while it is written
        // must still fit; dropping the key's credit here starts the cycle.
        repeat(10) {
            nowUs += frameUs
            q.enqueueDelta(1, nowUs, ByteArray(6_000))
        }
        assertEquals("no drop behind the sent key frame", 0, drops.get())
    }

    @Test
    fun `the encoder output scales the budget when the link has no sample`() {
        val drops = AtomicInteger()
        val q = queue(linkBps = null, drops = drops)
        // 10 x 50 KB at 60 fps = 24 Mbps, measured from the frames themselves.
        repeat(10) {
            nowUs += frameUs
            q.enqueueDelta(1, nowUs, ByteArray(50_000))
        }
        assertEquals("the encoder's own 24 Mbps admits 500 KB", 0, drops.get())
    }

    @Test
    fun `a slow measured link still drops its backlog`() {
        val drops = AtomicInteger()
        val q = queue(linkBps = 3_000_000, drops = drops)
        // 250 ms at 3 Mbps is 93 KB; 6 x 20 KB is over it.
        repeat(6) {
            nowUs += frameUs
            q.enqueueDelta(1, nowUs, ByteArray(20_000))
        }
        assertTrue("a 3 Mbps link drops a 120 KB backlog", drops.get() >= 1)
        assertNull("the backlog was discarded", q.pollNow())
    }
}
