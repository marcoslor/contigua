package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/**
 * Today's default policy (drop and ask for a keyframe at 250 ms of queued
 * video) measured the queued span from the first frame of a backlog, and only
 * reset it when the queue emptied. A writer that is one frame behind for a
 * whole scroll keeps one or two frames queued without ever emptying, so after
 * 250 ms of pts the next frame "overflowed" with ~33 ms actually queued: every
 * delta dropped and a keyframe asked for, with no link stall at all.
 */
class SendQueueSteadyBacklogTest {

    @Test
    fun `a writer one frame behind never overflows the default budget`() {
        val drops = AtomicInteger()
        val queue = SendQueue(onDeltaDrop = { drops.incrementAndGet() })
        val frameUs = 16_667L
        // One second at 60 fps. Before each new frame, the writer sends the
        // oldest one, so the queue holds two frames after every enqueue and
        // never runs dry.
        queue.enqueueDelta(1, 0, ByteArray(2_000))
        for (index in 1 until 60) {
            queue.enqueueDelta(1, index * frameUs, ByteArray(2_000))
            queue.pollNow()
        }
        assertEquals("no delta dropped with only two frames queued", 0, drops.get())
    }
}
