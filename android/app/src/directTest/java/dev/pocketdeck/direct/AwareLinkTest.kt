package dev.pocketdeck.direct

import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.ServerSocket

/**
 * The phone's Aware machine, every transition and every ignored event
 * (docs/design/direct-link.md §8.1, transport DIRECT-1/7/12/14). The machine is
 * pure: actions are values, so a test can name exactly what the platform would
 * be asked to do.
 */
class AwareLinkTest {

    private val network = object : AwareNetwork {
        override fun bindSocket(socket: ServerSocket) = Unit
    }

    private fun gates(
        switchOn: Boolean = true,
        permitted: Boolean = true,
        keyStored: Boolean = true,
        macDirectOn: Boolean = true,
    ) = AwareGates(switchOn, permitted, keyStored, macDirectOn)

    private fun link(gates: AwareGates = gates()) = AwareLink(gates)

    private fun assertStep(
        state: AwareLinkState,
        actions: List<AwareLinkAction>,
        step: AwareLinkStep,
    ) {
        assertEquals(state, step.state)
        assertEquals(actions, step.actions)
    }

    private val publishTeardown =
        listOf(AwareLinkAction.Unpublish, AwareLinkAction.Detach)
    private val ndpTeardown = listOf(AwareLinkAction.ReleaseNetwork)
    private val upTeardown = listOf(AwareLinkAction.ReleaseNetwork, AwareLinkAction.StopListener)

    // ---------------------------------------------------------------- Off

    @Test
    fun theSwitchAttachesOnlyWhenEveryGateHolds() {
        assertStep(
            AwareLinkState.Off, emptyList(),
            AwareLink(gates(switchOn = false, permitted = false)).transition(AwareLinkEvent.SwitchOn),
        )
        assertStep(
            AwareLinkState.Off, emptyList(),
            AwareLink(gates(switchOn = false, keyStored = false)).transition(AwareLinkEvent.SwitchOn),
        )
        assertStep(
            AwareLinkState.Off, emptyList(),
            AwareLink(gates(switchOn = false, macDirectOn = false)).transition(AwareLinkEvent.SwitchOn),
        )
        assertStep(
            AwareLinkState.Attaching, listOf(AwareLinkAction.Attach),
            AwareLink(gates(switchOn = false)).transition(AwareLinkEvent.SwitchOn),
        )
    }

    @Test
    fun aKeyArrivingLastStartsTheAttach() {
        assertStep(
            AwareLinkState.Attaching, listOf(AwareLinkAction.Attach),
            AwareLink(gates(keyStored = false)).transition(AwareLinkEvent.KeyStored),
        )
    }

    @Test
    fun aMacTurnedOnLastStartsTheAttach() {
        assertStep(
            AwareLinkState.Attaching, listOf(AwareLinkAction.Attach),
            AwareLink(gates(macDirectOn = false)).transition(AwareLinkEvent.MacDirectEnable(true)),
        )
    }

    @Test
    fun aPermissionGrantedLastStartsTheAttach() {
        assertStep(
            AwareLinkState.Attaching, listOf(AwareLinkAction.Attach),
            AwareLink(gates(permitted = false)).transition(AwareLinkEvent.PermissionChanged(true)),
        )
    }

    @Test
    fun offIgnoresEveryOtherEvent() {
        val machine = link(gates(switchOn = false))
        assertStep(AwareLinkState.Off, emptyList(), machine.transition(AwareLinkEvent.SwitchOff))
        assertStep(AwareLinkState.Off, listOf(AwareLinkAction.ReleaseNetwork), machine.transition(AwareLinkEvent.NdpAvailable(network)))
        assertStep(AwareLinkState.Off, emptyList(), machine.transition(AwareLinkEvent.Attached))
        assertStep(AwareLinkState.Off, emptyList(), machine.transition(AwareLinkEvent.PublishStarted))
        assertStep(AwareLinkState.Off, emptyList(), machine.transition(AwareLinkEvent.SessionEnded))
        assertStep(AwareLinkState.Off, emptyList(), machine.transition(AwareLinkEvent.NdpLost))
        assertStep(AwareLinkState.Off, emptyList(), machine.transition(AwareLinkEvent.SsiTick(7)))
        assertStep(AwareLinkState.Off, emptyList(), machine.transition(AwareLinkEvent.AwareStateChanged(true)))
    }

    // ----------------------------------------------------------- Attaching

    @Test
    fun attachedStartsOnePublish() {
        assertStep(
            AwareLinkState.Publishing(), listOf(AwareLinkAction.Publish),
            machineIn(AwareLinkState.Attaching).transition(AwareLinkEvent.Attached),
        )
    }

    @Test
    fun attachedWithoutTheGatesDetachesInstead() {
        val machine = machineIn(AwareLinkState.Attaching)
        assertStep(AwareLinkState.Off, listOf(AwareLinkAction.Detach), machine.transition(AwareLinkEvent.SwitchOff))
        // A late attach callback after the switch went off is dropped.
        assertStep(AwareLinkState.Off, emptyList(), machine.transition(AwareLinkEvent.Attached))
    }

    @Test
    fun attachingIgnoresPublishAndSessionCallbacks() {
        val machine = machineIn(AwareLinkState.Attaching)
        assertStep(AwareLinkState.Attaching, emptyList(), machine.transition(AwareLinkEvent.PublishStarted))
        assertStep(AwareLinkState.Attaching, emptyList(), machine.transition(AwareLinkEvent.SessionLive(true)))
        assertStep(AwareLinkState.Attaching, emptyList(), machine.transition(AwareLinkEvent.SessionEnded))
        assertStep(AwareLinkState.Attaching, emptyList(), machine.transition(AwareLinkEvent.NdpLost))
        assertStep(AwareLinkState.Attaching, emptyList(), machine.transition(AwareLinkEvent.SsiTick(1)))
        assertStep(AwareLinkState.Attaching, listOf(AwareLinkAction.ReleaseNetwork), machine.transition(AwareLinkEvent.NdpAvailable(network)))
    }

    @Test
    fun aRefusedAttachBlocksWithItsReason() {
        assertStep(
            AwareLinkState.Blocked("aware_busy"), listOf(AwareLinkAction.Detach),
            machineIn(AwareLinkState.Attaching).transition(AwareLinkEvent.PublishFailed("aware_busy")),
        )
    }

    // ---------------------------------------------------------- Publishing

    @Test
    fun aLiveSessionWithTheMacsSwitchOnStartsTheNdp() {
        assertStep(
            AwareLinkState.NdpPending(), listOf(AwareLinkAction.StartNdp),
            machineIn(AwareLinkState.Publishing()).transition(AwareLinkEvent.SessionLive(true)),
        )
    }

    @Test
    fun aLiveSessionWithTheMacsSwitchOffOnlyPublishes() {
        assertStep(
            AwareLinkState.Publishing(), emptyList(),
            machineIn(AwareLinkState.Publishing()).transition(AwareLinkEvent.SessionLive(false)),
        )
    }

    @Test
    fun theSsiTicksOncePerWindow() {
        val machine = machineIn(AwareLinkState.Publishing())
        assertStep(
            AwareLinkState.Publishing(100), listOf(AwareLinkAction.UpdateSsi(100)),
            machine.transition(AwareLinkEvent.SsiTick(100)),
        )
        assertStep(
            AwareLinkState.Publishing(100), emptyList(),
            machine.transition(AwareLinkEvent.SsiTick(100)),
        )
        assertStep(
            AwareLinkState.Publishing(101), listOf(AwareLinkAction.UpdateSsi(101)),
            machine.transition(AwareLinkEvent.SsiTick(101)),
        )
    }

    @Test
    fun publishingIgnoresTheLateCallbacks() {
        val machine = machineIn(AwareLinkState.Publishing())
        assertStep(AwareLinkState.Publishing(), emptyList(), machine.transition(AwareLinkEvent.PublishStarted))
        assertStep(AwareLinkState.Publishing(), emptyList(), machine.transition(AwareLinkEvent.Attached))
        assertStep(AwareLinkState.Publishing(), emptyList(), machine.transition(AwareLinkEvent.NdpLost))
        assertStep(AwareLinkState.Publishing(), emptyList(), machine.transition(AwareLinkEvent.SessionEnded))
        assertStep(AwareLinkState.Publishing(), listOf(AwareLinkAction.ReleaseNetwork), machine.transition(AwareLinkEvent.NdpAvailable(network)))
    }

    @Test
    fun aRefusedPublishBlocksAndTearsThePublishDown() {
        assertStep(
            AwareLinkState.Blocked("aware_busy"), publishTeardown,
            machineIn(AwareLinkState.Publishing()).transition(AwareLinkEvent.PublishFailed("aware_busy")),
        )
    }

    // ---------------------------------------------------------- NdpPending

    @Test
    fun anAvailableNdpBindsTheListener() {
        assertStep(
            AwareLinkState.Up(), listOf(AwareLinkAction.StartListener(network)),
            machineIn(AwareLinkState.NdpPending()).transition(AwareLinkEvent.NdpAvailable(network)),
        )
    }

    @Test
    fun aLostNdpKeepsPublishingForTheNextAttempt() {
        assertStep(
            AwareLinkState.Publishing(), ndpTeardown,
            machineIn(AwareLinkState.NdpPending()).transition(AwareLinkEvent.NdpLost),
        )
    }

    @Test
    fun theSessionEndingTearsTheNdpDownAndKeepsPublishing() {
        val machine = machineIn(AwareLinkState.NdpPending())
        assertStep(AwareLinkState.Publishing(), ndpTeardown, machine.transition(AwareLinkEvent.SessionEnded))
        assertStep(AwareLinkState.Publishing(), emptyList(), machine.transition(AwareLinkEvent.SessionEnded))
    }

    @Test
    fun theMacTurningItsSwitchOffEndsTheStandby() {
        assertStep(
            AwareLinkState.Publishing(), ndpTeardown,
            machineIn(AwareLinkState.NdpPending()).transition(AwareLinkEvent.SessionLive(false)),
        )
    }

    // ------------------------------------------------------------------ Up

    @Test
    fun upLosingTheNdpTearsTheListenerDownButKeepsPublishing() {
        for (event in listOf(AwareLinkEvent.NdpLost, AwareLinkEvent.SessionEnded, AwareLinkEvent.SessionLive(false))) {
            assertStep(AwareLinkState.Publishing(), upTeardown, machineIn(AwareLinkState.Up()).transition(event))
        }
    }

    @Test
    fun upStillTicksTheSsiAndReleasesAStrayNetwork() {
        val machine = machineIn(AwareLinkState.Up())
        assertStep(
            AwareLinkState.Up(9), listOf(AwareLinkAction.UpdateSsi(9)),
            machine.transition(AwareLinkEvent.SsiTick(9)),
        )
        assertStep(
            AwareLinkState.Up(9), listOf(AwareLinkAction.ReleaseNetwork),
            machine.transition(AwareLinkEvent.NdpAvailable(network)),
        )
    }

    // -------------------------------------------------------------- SwitchOff

    @Test
    fun theSwitchOffEndsEverythingFromEveryState() {
        val cases = listOf(
            AwareLinkState.Attaching to listOf(AwareLinkAction.Detach),
            AwareLinkState.Publishing(3) to publishTeardown,
            AwareLinkState.NdpPending(3) to (ndpTeardown + publishTeardown),
            AwareLinkState.Up(3) to (upTeardown + publishTeardown),
            AwareLinkState.Lost to emptyList(),
            AwareLinkState.Blocked("aware_busy") to emptyList(),
        )
        for ((state, actions) in cases) {
            assertStep(AwareLinkState.Off, actions, machineIn(state).transition(AwareLinkEvent.SwitchOff))
        }
    }

    @Test
    fun theKeyLeavingStopsPublishingAndTheStandby() {
        assertStep(
            AwareLinkState.Off, publishTeardown,
            machineIn(AwareLinkState.Publishing()).transition(AwareLinkEvent.KeyForgotten),
        )
        assertStep(
            AwareLinkState.Off, upTeardown + publishTeardown,
            machineIn(AwareLinkState.Up()).transition(AwareLinkEvent.KeyForgotten),
        )
    }

    @Test
    fun theMacTurningDirectOffStopsTheIdlePublishAndKeepsTheKey() {
        val machine = machineIn(AwareLinkState.Publishing())
        assertStep(AwareLinkState.Off, publishTeardown, machine.transition(AwareLinkEvent.MacDirectEnable(false)))
        // The key is still stored; the Mac turning it back on republishes.
        assertStep(
            AwareLinkState.Attaching, listOf(AwareLinkAction.Attach),
            machine.transition(AwareLinkEvent.MacDirectEnable(true)),
        )
    }

    // ----------------------------------------------------- permission + Aware

    @Test
    fun aDeniedPermissionBlocksFromEveryState() {
        val cases = listOf(
            AwareLinkState.Off to emptyList(),
            AwareLinkState.Attaching to listOf(AwareLinkAction.Detach),
            AwareLinkState.Publishing() to publishTeardown,
            AwareLinkState.NdpPending() to (ndpTeardown + publishTeardown),
            AwareLinkState.Up() to (upTeardown + publishTeardown),
            AwareLinkState.Lost to emptyList(),
            AwareLinkState.Blocked("aware_busy") to emptyList(),
        )
        for ((state, actions) in cases) {
            assertStep(
                AwareLinkState.Blocked("no_permission"), actions,
                machineIn(state).transition(AwareLinkEvent.PermissionDenied),
            )
        }
    }

    @Test
    fun aLostAwareStackTearsDownAndWaitsToReattach() {
        val cases = listOf(
            AwareLinkState.Attaching to listOf(AwareLinkAction.Detach),
            AwareLinkState.Publishing() to publishTeardown,
            AwareLinkState.NdpPending() to (ndpTeardown + publishTeardown),
            AwareLinkState.Up() to (upTeardown + publishTeardown),
        )
        for ((state, actions) in cases) {
            assertStep(AwareLinkState.Lost, actions, machineIn(state).transition(AwareLinkEvent.AwareStateChanged(false)))
        }
        // Off has nothing to tear down and stays Off.
        assertStep(
            AwareLinkState.Off, emptyList(),
            link(gates(switchOn = false)).transition(AwareLinkEvent.AwareStateChanged(false)),
        )
    }

    @Test
    fun awareComingBackReattaches() {
        assertStep(
            AwareLinkState.Attaching, listOf(AwareLinkAction.Attach),
            machineIn(AwareLinkState.Lost).transition(AwareLinkEvent.AwareStateChanged(true)),
        )
    }

    // -------------------------------------------------------------- Blocked

    @Test
    fun blockedRetriesWhenTheGatesRecover() {
        assertStep(
            AwareLinkState.Attaching, listOf(AwareLinkAction.Attach),
            machineIn(AwareLinkState.Blocked("aware_busy")).transition(AwareLinkEvent.SwitchOn),
        )
        assertStep(
            AwareLinkState.Attaching, listOf(AwareLinkAction.Attach),
            machineIn(AwareLinkState.Blocked("no_permission")).transition(AwareLinkEvent.PermissionChanged(true)),
        )
    }

    @Test
    fun blockedIgnoresWhatCannotRecoverIt() {
        val machine = machineIn(AwareLinkState.Blocked("aware_busy"))
        assertStep(AwareLinkState.Blocked("aware_busy"), emptyList(), machine.transition(AwareLinkEvent.Attached))
        assertStep(AwareLinkState.Blocked("aware_busy"), emptyList(), machine.transition(AwareLinkEvent.PublishStarted))
        assertStep(AwareLinkState.Blocked("aware_busy"), emptyList(), machine.transition(AwareLinkEvent.SessionLive(true)))
        assertStep(AwareLinkState.Blocked("aware_busy"), emptyList(), machine.transition(AwareLinkEvent.NdpLost))
        assertStep(AwareLinkState.Blocked("aware_busy"), emptyList(), machine.transition(AwareLinkEvent.SsiTick(2)))
    }

    // ----------------------------------------------------- platform refusal

    @Test
    fun thePhoneWithoutTheFeatureBlocksEvenWithEveryGate() {
        assertStep(
            AwareLinkState.Blocked("no_feature"), emptyList(),
            machineIn(AwareLinkState.Off).transition(AwareLinkEvent.PlatformBlocked("no_feature")),
        )
        assertStep(
            AwareLinkState.Blocked("location_off"),
            publishTeardown,
            machineIn(AwareLinkState.Publishing()).transition(AwareLinkEvent.PlatformBlocked("location_off")),
        )
        assertStep(
            AwareLinkState.Blocked("aware_busy"),
            listOf(
                AwareLinkAction.ReleaseNetwork, AwareLinkAction.StopListener,
                AwareLinkAction.Unpublish, AwareLinkAction.Detach,
            ),
            machineIn(AwareLinkState.Up()).transition(AwareLinkEvent.PlatformBlocked("aware_busy")),
        )
    }

    // -------------------------------------------------------------- logging

    @Test
    fun everyStateChangeLogsClosedTokensOnly() {
        val lines = mutableListOf<String>()
        val machine = AwareLink(gates(switchOn = false), { lines.add(it) })
        machine.transition(AwareLinkEvent.SwitchOn)
        machine.transition(AwareLinkEvent.Attached)
        machine.transition(AwareLinkEvent.SessionLive(true))
        machine.transition(AwareLinkEvent.NdpAvailable(network))
        assertEquals(
            listOf(
                "aware: off --switch_on--> attaching",
                "aware: attaching --attached--> publishing",
                "aware: publishing --connected--> ndp_pending",
                "aware: ndp_pending --ndp_available--> up",
            ),
            lines,
        )
    }

    /** Builds a machine already in [state] through its real transitions. */
    private fun machineIn(state: AwareLinkState, gates: AwareGates = gates()): AwareLink {
        val machine = AwareLink(gates)
        fun reach(target: AwareLinkState) {
            if (machine.state == target) return
            when (target) {
                AwareLinkState.Off -> machine.transition(AwareLinkEvent.SwitchOff)
                AwareLinkState.Attaching -> machine.transition(AwareLinkEvent.SwitchOn)
                is AwareLinkState.Publishing -> {
                    reach(AwareLinkState.Attaching)
                    machine.transition(AwareLinkEvent.Attached)
                    target.window?.let { machine.transition(AwareLinkEvent.SsiTick(it)) }
                }
                is AwareLinkState.NdpPending -> {
                    reach(AwareLinkState.Publishing())
                    machine.transition(AwareLinkEvent.SessionLive(true))
                    target.window?.let { machine.transition(AwareLinkEvent.SsiTick(it)) }
                }
                is AwareLinkState.Up -> {
                    reach(AwareLinkState.NdpPending())
                    machine.transition(AwareLinkEvent.NdpAvailable(network))
                    target.window?.let { machine.transition(AwareLinkEvent.SsiTick(it)) }
                }
                AwareLinkState.Lost -> {
                    reach(AwareLinkState.Attaching)
                    machine.transition(AwareLinkEvent.AwareStateChanged(false))
                }
                is AwareLinkState.Blocked -> {
                    reach(AwareLinkState.Attaching)
                    machine.transition(AwareLinkEvent.PermissionDenied)
                    if (target.reason != "no_permission") {
                        machine.transition(AwareLinkEvent.PermissionChanged(true))
                        machine.transition(AwareLinkEvent.PublishFailed(target.reason))
                    }
                }
            }
        }
        reach(state)
        assertEquals("the helper reached its state", state, machine.state)
        return machine
    }

    @Test
    fun theHelperReachesEveryState() {
        val states = listOf(
            AwareLinkState.Off,
            AwareLinkState.Attaching,
            AwareLinkState.Publishing(4),
            AwareLinkState.NdpPending(4),
            AwareLinkState.Up(4),
            AwareLinkState.Lost,
            AwareLinkState.Blocked("no_permission"),
            AwareLinkState.Blocked("aware_busy"),
        )
        for (state in states) {
            assertEquals(state, machineIn(state).state)
        }
    }
}
