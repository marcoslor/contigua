package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Q1 on more than one thread: the queue's transitions happen under its lock,
 * but the encoder was told about them afterwards, as edges. Two threads can
 * apply their edges in the opposite order of their transitions, and the last
 * edge wins even when a newer state exists.
 */
class SendQueueSuspendRaceTest {

    @Test
    fun `a suspend applied after its resume cannot leave the encoder stuck`() {
        val applied = CopyOnWriteArrayList<Boolean>()
        val suspendEntered = CountDownLatch(1)
        val releaseSuspend = CountDownLatch(1)
        lateinit var queue: SendQueue
        queue = SendQueue(
            maxDeltaBytesPerStream = 100,
            policyFor = {
                QueuePolicy(StreamStrategy.Overflow.Suspend, maxBytes = 100,
                            maxDurationUs = 10_000_000)
            },
            onSuspendChanged = { stream ->
                if (queue.isSuspended(stream)) {
                    // The encoder-thread apply reaches the display late.
                    suspendEntered.countDown()
                    releaseSuspend.await(2, TimeUnit.SECONDS)
                }
                applied.add(queue.isSuspended(stream))
            },
        )
        val producer = Thread({
            queue.enqueueDelta(1, 0, ByteArray(60))
            queue.enqueueDelta(1, 16_667, ByteArray(60))
        })
        producer.start()
        assertTrue("the pressure transition suspended", suspendEntered.await(2, TimeUnit.SECONDS))

        // The writer thread drains the whole backlog while the first apply is held.
        assertEquals(60, queue.pollNow()!!.bytes.size)
        assertEquals(60, queue.pollNow()!!.bytes.size)

        releaseSuspend.countDown()
        producer.join(2_000)
        assertFalse("the encoder may not stay suspended after the queue drained",
                    applied.last())
    }
}
