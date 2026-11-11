package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The pure handshake gate: master switch, pairing switch, a Mac that believes
 * it is paired, and fail closed (docs/specs/pairing.md PAIR-12, PAIR-23).
 */
class ConnectionGateTest {

    @Test
    fun bothOnAcceptsAnyMac() {
        val settings = GateSettings(allowConnections = true, allowPairings = true)
        assertEquals(GateDecision.ACCEPT, ConnectionGate.decide(settings, isPaired = true, isPairing = false))
        assertEquals(GateDecision.ACCEPT, ConnectionGate.decide(settings, isPaired = false, isPairing = true))
    }

    @Test
    fun aMacWithNoPinThatDidNotAskToPairIsAnsweredNotPaired() {
        val settings = GateSettings(allowConnections = true, allowPairings = true)
        assertEquals(
            GateDecision.NOT_PAIRED,
            ConnectionGate.decide(settings, isPaired = false, isPairing = false),
        )
        assertEquals("not_paired", GateDecision.NOT_PAIRED.code)
    }

    @Test
    fun masterOffRefusesPairedAndUnknownMacs() {
        val settings = GateSettings(allowConnections = false, allowPairings = true)
        for (paired in listOf(true, false)) {
            for (pairing in listOf(true, false)) {
                assertEquals(
                    GateDecision.REFUSE_CONNECTIONS_OFF,
                    ConnectionGate.decide(settings, isPaired = paired, isPairing = pairing),
                )
            }
        }
    }

    @Test
    fun pairingsOffRefusesOnlyUnknownMacsThatAskedToPair() {
        val settings = GateSettings(allowConnections = true, allowPairings = false)
        assertEquals(GateDecision.ACCEPT, ConnectionGate.decide(settings, isPaired = true, isPairing = false))
        assertEquals(GateDecision.ACCEPT, ConnectionGate.decide(settings, isPaired = true, isPairing = true))
        assertEquals(
            GateDecision.REFUSE_PAIRING_OFF,
            ConnectionGate.decide(settings, isPaired = false, isPairing = true),
        )
        // PAIR-12: a peer the phone pins nothing for, which did not ask to pair,
        // is closed without a word.
        assertEquals(
            GateDecision.CLOSE_SILENT,
            ConnectionGate.decide(settings, isPaired = false, isPairing = false),
        )
        assertEquals(null, GateDecision.CLOSE_SILENT.code)
    }

    @Test
    fun bothOffRefusesEverythingWithTheMasterReason() {
        val settings = GateSettings(allowConnections = false, allowPairings = false)
        for (paired in listOf(true, false)) {
            for (pairing in listOf(true, false)) {
                assertEquals(
                    GateDecision.REFUSE_CONNECTIONS_OFF,
                    ConnectionGate.decide(settings, isPaired = paired, isPairing = pairing),
                )
            }
        }
    }

    @Test
    fun unreadableSettingsFailClosed() {
        // The app never pushed the stored values: refuse like the master is off,
        // never fall back to the permissive defaults.
        for (paired in listOf(true, false)) {
            for (pairing in listOf(true, false)) {
                assertEquals(
                    GateDecision.REFUSE_CONNECTIONS_OFF,
                    ConnectionGate.decide(null, isPaired = paired, isPairing = pairing),
                )
            }
        }
    }
}
