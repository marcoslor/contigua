package dev.pocketdeck.direct

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * DIRECT-1's publish gate: the phone publishes only with its own switch on, the
 * permission granted, a stored key for a paired Mac whose stored
 * `direct.enable` is on — and a live session is not one of the conditions.
 */
class DirectSwitchTest {

    private fun gates(
        switchOn: Boolean = true,
        permitted: Boolean = true,
        keyStored: Boolean = true,
        macDirectOn: Boolean = true,
    ) = AwareGates(switchOn, permitted, keyStored, macDirectOn)

    @Test
    fun everyOneOfTheFourConditionsIsRequired() {
        // The switch is off: a key arriving is not enough.
        assertEquals(
            AwareLinkState.Off,
            AwareLink(gates(switchOn = false)).transition(AwareLinkEvent.KeyStored).state,
        )
        // Each other condition missing: turning the switch on stays Off.
        for (g in listOf(gates(permitted = false), gates(keyStored = false), gates(macDirectOn = false))) {
            assertEquals(
                "no attach without every condition ($g)",
                AwareLinkState.Off,
                AwareLink(g).transition(AwareLinkEvent.SwitchOn).state,
            )
        }
    }

    @Test
    fun noSessionIsNeededToPublish() {
        val machine = AwareLink(gates())
        assertEquals(AwareLinkState.Attaching, machine.transition(AwareLinkEvent.SwitchOn).state)
        val step = machine.transition(AwareLinkEvent.Attached)
        assertEquals(AwareLinkState.Publishing(), step.state)
        assertEquals(listOf(AwareLinkAction.Publish), step.actions)
    }

    @Test
    fun aLiveSessionAloneNeverPublishes() {
        val machine = AwareLink(gates(switchOn = false))
        val step = machine.transition(AwareLinkEvent.SessionLive(true))
        assertEquals(AwareLinkState.Off, step.state)
        assertEquals(emptyList<AwareLinkAction>(), step.actions)
    }
}
