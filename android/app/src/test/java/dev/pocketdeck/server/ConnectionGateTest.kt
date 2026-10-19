package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

/** The pure handshake gate: master switch, pairing switch, and fail closed. */
class ConnectionGateTest {

    @Test
    fun bothOnAcceptsAnyMac() {
        val settings = GateSettings(allowConnections = true, allowPairings = true)
        assertEquals(GateDecision.ACCEPT, ConnectionGate.decide(settings, isPaired = true))
        assertEquals(GateDecision.ACCEPT, ConnectionGate.decide(settings, isPaired = false))
    }

    @Test
    fun masterOffRefusesPairedAndUnknownMacs() {
        val settings = GateSettings(allowConnections = false, allowPairings = true)
        assertEquals(
            GateDecision.REFUSE_CONNECTIONS_OFF,
            ConnectionGate.decide(settings, isPaired = true),
        )
        assertEquals(
            GateDecision.REFUSE_CONNECTIONS_OFF,
            ConnectionGate.decide(settings, isPaired = false),
        )
    }

    @Test
    fun pairingsOffRefusesOnlyUnknownMacs() {
        val settings = GateSettings(allowConnections = true, allowPairings = false)
        assertEquals(GateDecision.ACCEPT, ConnectionGate.decide(settings, isPaired = true))
        assertEquals(
            GateDecision.REFUSE_PAIRING_OFF,
            ConnectionGate.decide(settings, isPaired = false),
        )
    }

    @Test
    fun bothOffRefusesEverythingWithTheMasterReason() {
        val settings = GateSettings(allowConnections = false, allowPairings = false)
        assertEquals(
            GateDecision.REFUSE_CONNECTIONS_OFF,
            ConnectionGate.decide(settings, isPaired = true),
        )
        assertEquals(
            GateDecision.REFUSE_CONNECTIONS_OFF,
            ConnectionGate.decide(settings, isPaired = false),
        )
    }

    @Test
    fun unreadableSettingsFailClosed() {
        // The app never pushed the stored values: refuse like the master is off,
        // never fall back to the permissive defaults.
        assertEquals(
            GateDecision.REFUSE_CONNECTIONS_OFF,
            ConnectionGate.decide(null, isPaired = true),
        )
        assertEquals(
            GateDecision.REFUSE_CONNECTIONS_OFF,
            ConnectionGate.decide(null, isPaired = false),
        )
    }
}
