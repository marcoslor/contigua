package app.contigua.server

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

    /**
     * The phone's drop rule throws deltas away after an IDR and waits for the
     * next key: that IDR can no longer start the decoder, so it answers nothing
     * (the person's YouTube launch, 2026-11-09 14:19: the request was satisfied
     * by an IDR 97 ms old, no key came, and the window said "Not responding").
     */
    @Test
    fun `a delta drop after the idr leaves nothing to answer a request`() {
        gate.onIdr(1_000)
        gate.onDeltasDropped()
        assertEquals(KeyRequestGate.KeyRequest.Send, gate.onRequest(1_097))
    }

    @Test
    fun `an idr after the drop answers again`() {
        gate.onIdr(1_000)
        gate.onDeltasDropped()
        gate.onIdr(1_200)
        assertEquals(KeyRequestGate.KeyRequest.Satisfied(50), gate.onRequest(1_250))
    }

    @Test
    fun `a reset forgets the idr`() {
        gate.onIdr(1_000)
        gate.reset()
        assertEquals(KeyRequestGate.KeyRequest.Send, gate.onRequest(1_100))
    }
}
