package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.CopyOnWriteArrayList

/**
 * Q1's resume rule when the backlog empties: the duration rule kept the first
 * frame's pts after it was dequeued, so the last dequeue still saw a span over
 * half the budget, returned early, and then the maps were removed. The stream
 * stayed suspended with an empty queue and no later dequeue could resume it.
 */
class SendQueueDrainTest {

    @Test
    fun `the last delta dequeued resumes a suspended stream`() {
        val applied = CopyOnWriteArrayList<Boolean>()
        lateinit var queue: SendQueue
        queue = SendQueue(
            maxDeltaBytesPerStream = 1_000_000,
            maxDeltaDurationUs = 100_000,
            policyFor = {
                QueuePolicy(StreamStrategy.Overflow.Suspend, maxBytes = 1_000_000,
                            maxDurationUs = 100_000)
            },
            onSuspendChanged = { stream -> applied.add(queue.isSuspended(stream)) },
        )
        queue.enqueueDelta(1, 0, ByteArray(10))
        queue.enqueueDelta(1, 60_000, ByteArray(10))
        // 120 ms of queued video is past the 100 ms budget: suspend.
        queue.enqueueDelta(1, 120_000, ByteArray(10))
        assertEquals(listOf(true), applied)

        while (queue.pollNow() != null) Unit

        assertEquals("empty is drained", listOf(true, false), applied)
    }
}
