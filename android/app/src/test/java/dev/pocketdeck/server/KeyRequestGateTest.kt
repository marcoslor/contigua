package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The duplicate-keyframe rule: a fresh encoder starts on an IDR, so a key
 * request inside 250 ms after it is already satisfied; the Mac's 500 ms retry
 * is not.
 */
class KeyRequestGateTest {

    private val gate = KeyRequestGate()

    @Test
    fun `a request inside the window is satisfied by the idr`() {
        gate.onIdr(1_000)
        assertEquals(KeyRequestGate.KeyRequest.Satisfied(0), gate.onRequest(1_000))
        assertEquals(KeyRequestGate.KeyRequest.Satisfied(250), gate.onRequest(1_250))
    }

    @Test
    fun `a request after the window is honoured`() {
        gate.onIdr(1_000)
        assertEquals(KeyRequestGate.KeyRequest.Send, gate.onRequest(1_251))
    }

    @Test
    fun `the five hundred millisecond retry is honoured`() {
        gate.onIdr(1_000)
        assertEquals(KeyRequestGate.KeyRequest.Satisfied(100), gate.onRequest(1_100))
        assertEquals(KeyRequestGate.KeyRequest.Send, gate.onRequest(1_500))
    }

    @Test
    fun `a request before the idr is honoured`() {
        gate.onIdr(1_000)
        assertEquals(KeyRequestGate.KeyRequest.Send, gate.onRequest(999))
    }

    @Test
    fun `a reset forgets the idr`() {
        gate.onIdr(1_000)
        gate.reset()
        assertEquals(KeyRequestGate.KeyRequest.Send, gate.onRequest(1_100))
    }
}
