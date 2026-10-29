package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The one-session slot's state machine (docs/specs/pairing.md PAIR-21): every
 * state and every event, including the events a state must ignore.
 */
class SessionSlotTest {

    private val free = SlotState.Free
    private val live = SlotState.Live("aa")
    private val draining = SlotState.Draining("aa")
    private val handing = SlotState.Handing(old = "aa", new = "bb")

    @Test
    fun freeAdoptsTheFirstMac() {
        assertEquals(
            SlotStep(SlotState.Live("aa"), listOf(SlotAction.ADOPT)),
            SessionSlot.transition(free, SlotEvent.Connect("aa", samePinnedMac = false)),
        )
    }

    @Test
    fun freeIgnoresTheEventsOfSessionsItDoesNotHold() {
        for (event in listOf(SlotEvent.Ending, SlotEvent.TeardownDone, SlotEvent.TeardownSlow, SlotEvent.Ended)) {
            assertEquals(SlotStep(free, emptyList()), SessionSlot.transition(free, event))
        }
    }

    @Test
    fun theSamePinnedMacHandsTheSlotOver() {
        assertEquals(
            SlotStep(SlotState.Handing(old = "aa", new = "aa"), listOf(SlotAction.DROP_OLD, SlotAction.AWAIT_TEARDOWN)),
            SessionSlot.transition(live, SlotEvent.Connect("aa", samePinnedMac = true)),
        )
    }

    @Test
    fun aDifferentUnpinnedOrPairingMacIsBusy() {
        assertEquals(
            SlotStep(live, listOf(SlotAction.BUSY)),
            SessionSlot.transition(live, SlotEvent.Connect("bb", samePinnedMac = false)),
        )
    }

    @Test
    fun aLiveSessionThatCanNoLongerServeDrains() {
        assertEquals(SlotStep(draining, emptyList()), SessionSlot.transition(live, SlotEvent.Ending))
        assertEquals(
            SlotStep(SlotState.Draining(null), emptyList()),
            SessionSlot.transition(SlotState.Live(null), SlotEvent.Ending),
        )
    }

    @Test
    fun aLiveSlotIgnoresTeardownsOfOtherSessions() {
        for (event in listOf(SlotEvent.TeardownDone, SlotEvent.TeardownSlow)) {
            assertEquals(SlotStep(live, emptyList()), SessionSlot.transition(live, event))
        }
    }

    @Test
    fun aLiveSlotIsFreedByItsOwnEnd() {
        assertEquals(SlotStep(free, emptyList()), SessionSlot.transition(live, SlotEvent.Ended))
    }

    @Test
    fun anyMacWaitsForADrainingTeardownInsteadOfHearingBusy() {
        for (same in listOf(false, true)) {
            val connect = SlotEvent.Connect(if (same) "aa" else "bb", same)
            assertEquals(
                SlotStep(SlotState.Handing(old = "aa", new = connect.peerMac), listOf(SlotAction.DROP_OLD, SlotAction.AWAIT_TEARDOWN)),
                SessionSlot.transition(draining, connect),
            )
        }
    }

    @Test
    fun aDrainingSlotIsFreedByItsEndAndIgnoresEarlierSignals() {
        assertEquals(SlotStep(free, emptyList()), SessionSlot.transition(draining, SlotEvent.Ended))
        for (event in listOf(SlotEvent.Ending, SlotEvent.TeardownDone, SlotEvent.TeardownSlow)) {
            assertEquals(SlotStep(draining, emptyList()), SessionSlot.transition(draining, event))
        }
    }

    @Test
    fun aRunningHandoverAdmitsTheWaitingMacWhenTheTeardownIsDone() {
        assertEquals(
            SlotStep(SlotState.Live("bb"), listOf(SlotAction.ADOPT)),
            SessionSlot.transition(handing, SlotEvent.TeardownDone),
        )
    }

    @Test
    fun aRunningHandoverAnswersBusyWhenTheTeardownIsSlow() {
        assertEquals(
            SlotStep(SlotState.Live("aa"), listOf(SlotAction.BUSY_SLOW)),
            SessionSlot.transition(handing, SlotEvent.TeardownSlow),
        )
    }

    @Test
    fun aRunningHandoverTakesNoSecondMac() {
        for (same in listOf(true, false)) {
            assertEquals(
                SlotStep(handing, listOf(SlotAction.BUSY)),
                SessionSlot.transition(handing, SlotEvent.Connect("bb", samePinnedMac = same)),
            )
        }
    }

    @Test
    fun aRunningHandoverIgnoresTheOldSessionsEnd() {
        // Its end is the latch the waiter is on, never a second transition.
        for (event in listOf(SlotEvent.Ending, SlotEvent.Ended)) {
            assertEquals(SlotStep(handing, emptyList()), SessionSlot.transition(handing, event))
        }
    }

    @Test
    fun everyDescriptionIsAClosedToken() {
        assertEquals(
            setOf("free", "live", "draining", "handing"),
            listOf(free, live, draining, handing).map(SessionSlot::describe).toSet(),
        )
        assertEquals(
            setOf("connect(same mac)", "connect(other mac)", "ending", "teardown done", "teardown slow", "ended"),
            listOf(
                SlotEvent.Connect("aa", true), SlotEvent.Connect("bb", false), SlotEvent.Ending,
                SlotEvent.TeardownDone, SlotEvent.TeardownSlow, SlotEvent.Ended,
            ).map(SessionSlot::describe).toSet(),
        )
    }
}
