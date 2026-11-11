package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test

/** The clipboard gate's one transition, every state/event pair (SHARE-13). */
class ClipGateTest {

    @Test
    fun `the mac's word is the state`() {
        assertEquals(ClipGate.ON, clipGate(ClipGate.OFF, ClipGateEvent.MacSaid(true)))
        assertEquals(ClipGate.OFF, clipGate(ClipGate.ON, ClipGateEvent.MacSaid(false)))
        // Repeats are the same state: a second enable changes nothing.
        assertEquals(ClipGate.ON, clipGate(ClipGate.ON, ClipGateEvent.MacSaid(true)))
        assertEquals(ClipGate.OFF, clipGate(ClipGate.OFF, ClipGateEvent.MacSaid(false)))
    }
}
