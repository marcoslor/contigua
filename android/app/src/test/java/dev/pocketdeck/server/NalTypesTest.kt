package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer

/** ISS-40 round 3: the NAL types at the front of an access unit. */
class NalTypesTest {

    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { v[it].toByte() }

    @Test
    fun anIdrAccessUnitCarriesItsSpsPpsAndIdrSlice() {
        val au = bytes(0, 0, 0, 1, 0x67, 1,
                       0, 0, 1, 0x68, 2,
                       0, 0, 0, 1, 0x65, 3)
        assertEquals(listOf(7, 8, 5), nalTypes(au))
    }

    @Test
    fun aPSliceIsATypeOne() {
        assertEquals(listOf(1), nalTypes(bytes(0, 0, 1, 0x41, 9)))
    }

    @Test
    fun anSeiBeforeASliceIsNamedToo() {
        val au = bytes(0, 0, 0, 1, 0x06, 0x05, 1, 2, 3,
                       0, 0, 1, 0x41, 9)
        assertEquals(listOf(6, 1), nalTypes(au))
    }

    @Test
    fun theScanStopsAfterTheFirstSlice() {
        // An AUD after the slice belongs to a later unit and must not be read.
        val au = bytes(0, 0, 1, 0x67, 1,
                       0, 0, 1, 0x65, 2,
                       0, 0, 1, 0x09, 3)
        assertEquals(listOf(7, 5), nalTypes(au))
    }

    @Test
    fun bothStartCodeWidthsAreFound() {
        assertEquals(listOf(7), nalTypes(bytes(0, 0, 0, 1, 0x67, 1)))
        assertEquals(listOf(7), nalTypes(bytes(0, 0, 1, 0x67, 1)))
    }

    @Test
    fun aTruncatedBufferStopsAtTheBytesItHas() {
        // A header with no body is complete enough for its type.
        assertEquals(listOf(7), nalTypes(bytes(0, 0, 0, 1, 0x67)))
        // A start code with no header byte is not a unit.
        assertEquals(emptyList<Int>(), nalTypes(bytes(0, 0, 1)))
        assertEquals(emptyList<Int>(), nalTypes(bytes(0, 0, 0, 1)))
    }

    @Test
    fun theLimitBoundsTheScan() {
        assertEquals(emptyList<Int>(), nalTypes(bytes(0, 0, 1, 0x67), 2))
        assertEquals(listOf(7), nalTypes(bytes(0, 0, 1, 0x67), 4))
    }

    @Test
    fun theBuffersPositionAndLimitAreUnchanged() {
        val au = bytes(0, 0, 0, 1, 0x67, 1,
                       0, 0, 1, 0x68, 2,
                       0, 0, 1, 0x65, 3)
        val buffer = ByteBuffer.wrap(bytes(0xAA, 0xBB) + au)
        buffer.position(2)
        buffer.limit(2 + au.size)
        val position = buffer.position()
        val limit = buffer.limit()
        assertEquals(listOf(7, 8, 5), nalTypes(buffer, au.size))
        assertEquals(position, buffer.position())
        assertEquals(limit, buffer.limit())
    }
}
