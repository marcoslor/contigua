package dev.pocketdeck.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** docs/design/paths.md §5.3/§8, PATH-4/9/10. */
class ReorderWindowTest {
    private fun frame(seq: Long, bytes: Int = 4) =
        PathCodec.Reliable(seq, Frame(Frames.TYPE_JSON, 0, ByteArray(bytes) { seq.toByte() }))

    @Test
    fun inOrderFramesAreDeliveredAndTheAckAdvances() {
        val window = ReorderWindow()
        val first = window.receive(frame(1)) as ReorderWindow.Result.Deliver
        assertEquals(listOf(1L), first.frames.map { it.seq })
        assertEquals(2L, window.ack)
        val second = window.receive(frame(2)) as ReorderWindow.Result.Deliver
        assertEquals(listOf(2L), second.frames.map { it.seq })
        assertEquals(3L, window.ack)
    }

    @Test
    fun aGapHoldsFramesUntilItFills() {
        val window = ReorderWindow()
        assertEquals(ReorderWindow.Result.Buffered, window.receive(frame(2)))
        assertEquals(ReorderWindow.Result.Buffered, window.receive(frame(3)))
        assertEquals(1L, window.ack)
        assertEquals(2, window.bufferedCount)
        val delivered = window.receive(frame(1)) as ReorderWindow.Result.Deliver
        assertEquals(listOf(1L, 2L, 3L), delivered.frames.map { it.seq })
        assertEquals(4L, window.ack)
    }

    @Test
    fun aDuplicateIsDroppedAndNeverDeliveredTwice() {
        val window = ReorderWindow()
        window.receive(frame(1))
        assertEquals(ReorderWindow.Result.Duplicate, window.receive(frame(1)))
        assertEquals(ReorderWindow.Result.Duplicate, window.receive(frame(0)))
        assertEquals(ReorderWindow.Result.Buffered, window.receive(frame(3)))
        assertEquals(ReorderWindow.Result.Duplicate, window.receive(frame(3)))
        val closed = window.receive(frame(2)) as ReorderWindow.Result.Deliver
        assertEquals(listOf(2L, 3L), closed.frames.map { it.seq })
    }

    @Test
    fun sixtyFourBufferedFramesFitAndTheSixtyFifthIsFull() {
        val window = ReorderWindow()
        for (seq in 2L..65L) assertEquals(ReorderWindow.Result.Buffered, window.receive(frame(seq)))
        assertEquals(64, window.bufferedCount)
        assertEquals(ReorderWindow.Result.Full, window.receive(frame(66)))
        assertEquals(64, window.bufferedCount)
        val delivered = window.receive(frame(1)) as ReorderWindow.Result.Deliver
        assertEquals(65, delivered.frames.size)
    }

    @Test
    fun theFourMiBByteWindowStopsTheReadToo() {
        val window = ReorderWindow()
        for (seq in 2L..5L) {
            assertEquals(ReorderWindow.Result.Buffered, window.receive(frame(seq, 1 shl 20)))
        }
        assertEquals(ReorderWindow.Result.Full, window.receive(frame(6, 1 shl 20)))
        assertEquals(4 shl 20, window.bufferedBytes)
    }

    @Test
    fun resetForgetsTheWindowForANewSession() {
        val window = ReorderWindow()
        window.receive(frame(2))
        window.reset()
        assertEquals(1L, window.ack)
        assertEquals(0, window.bufferedCount)
    }
}
