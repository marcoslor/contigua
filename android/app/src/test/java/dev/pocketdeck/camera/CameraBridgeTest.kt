package dev.pocketdeck.camera

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.IOException

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The shell half's two pure pieces (K1): the access-unit framing parser and the
 * `cameraState` relay. The AIDL itself is exercised on the emulator boot.
 */
class CameraBridgeTest {

    private fun frame(ptsUs: Long, key: Boolean, data: ByteArray): ByteArray {
        val out = ByteArrayOutputStream()
        CameraAu.write(out, ptsUs, key, data)
        return out.toByteArray()
    }

    @Test
    fun readerRecoversEveryRecordInOrder() {
        val out = ByteArrayOutputStream()
        CameraAu.write(out, 1L, true, byteArrayOf(0, 0, 0, 1, 0x67))
        CameraAu.write(out, 33_000L, false, byteArrayOf(0, 0, 0, 1, 0x41, 2, 3))
        CameraAu.write(out, 66_000L, true, byteArrayOf(9))

        val reader = CameraAuReader(ByteArrayInputStream(out.toByteArray()))
        val a = reader.next()!!
        assertTrue(a.key)
        assertEquals(1L, a.ptsUs)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 0x67), a.data)

        val b = reader.next()!!
        assertFalse(b.key)
        assertEquals(33_000L, b.ptsUs)
        assertEquals(7, b.data.size)

        val c = reader.next()!!
        assertTrue(c.key)
        assertEquals(66_000L, c.ptsUs)

        assertNull(reader.next())
    }

    @Test
    fun cleanEofIsNotAnError() {
        assertNull(CameraAuReader(ByteArrayInputStream(ByteArray(0))).next())
    }

    @Test
    fun truncatedHeaderAndPayloadThrow() {
        val full = frame(5L, true, byteArrayOf(1, 2, 3, 4))
        assertThrows(EOFException::class.java) {
            CameraAuReader(ByteArrayInputStream(full.copyOf(6))).next()
        }
        assertThrows(EOFException::class.java) {
            CameraAuReader(ByteArrayInputStream(full.copyOf(full.size - 2))).next()
        }
    }

    @Test
    fun absurdLengthIsRefused() {
        val head = ByteArray(13)
        CameraAu.putInt(head, 0, CameraAu.MAX_BYTES + 1)
        assertThrows(IOException::class.java) {
            CameraAuReader(ByteArrayInputStream(head)).next()
        }
        val zero = ByteArray(13)
        CameraAu.putInt(zero, 0, 0)
        assertThrows(IOException::class.java) {
            CameraAuReader(ByteArrayInputStream(zero)).next()
        }
    }

    @Test
    fun writerRefusesAnEmptyAccessUnit() {
        val out = ByteArrayOutputStream()
        assertThrows(IOException::class.java) {
            CameraAu.write(out, 0L, false, ByteArray(0))
        }
    }

    // ---- the state relay ------------------------------------------------

    @Test
    fun gatePushIsRecognised() {
        val json = CameraMessages.gate(true, listOf(CameraInfo("0", "back", 1920, 1080)))
        val update = CameraRelay.parse(json)!!
        assertTrue(update.hasGate)
        assertFalse(update.hasState)
        assertEquals(true, update.allowed)
        assertEquals(1, update.cams!!.size)
        assertEquals("0", update.cams!![0].id)
    }

    @Test
    fun statePushKeepsItsStreamAndReason() {
        val update = CameraRelay.parse(CameraMessages.state(12, CameraState.EVICTED, "onDisconnected"))!!
        assertFalse(update.hasGate)
        assertTrue(update.hasState)
        assertEquals(12, update.stream)
        assertEquals("evicted", update.state)
        assertEquals("onDisconnected", update.reason)

        val wire = CameraMessages.wireState(update.stream!!, update.state!!, update.reason)
        assertEquals("cam.state", wire["t"])
        assertEquals(12, wire["stream"])
        assertEquals("evicted", wire["state"])
        assertEquals("onDisconnected", wire["reason"])
    }

    @Test
    fun malformedPushIsIgnored() {
        assertNull(CameraRelay.parse("not json"))
        assertNull(CameraRelay.parse("""{"other":1}""").let {
            if (it != null && !it.hasGate && !it.hasState) null else it
        })
    }
}
