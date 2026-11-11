package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The one-session slot's state machine (docs/specs/pairing.md PAIR-21): every
 * state and every event, including the events a state must ignore. The session
 * is a string here: the machine only carries it.
 */
class SessionSlotTest {

    private val free = SlotState.Free
    private val live = SlotState.Live("aa", "s1")
    private val draining = SlotState.Draining("aa", "s1")
    private val handing = SlotState.Handing(old = "s1", oldMac = "aa", newMac = "bb")

    @Test
    fun freeAsksTheCallerToAdoptTheFirstMac() {
        assertEquals(
            SlotStep(SlotState.Free, listOf(SlotAction.ADOPT)),
            SessionSlot.transition(free, SlotEvent.Connect("aa", samePinnedMac = false)),
        )
        // The caller's session is what makes the slot live.
        assertEquals(SlotState.Live("aa", "s1"), SessionSlot.adopt(free, "aa", "s1"))
        assertEquals(SlotState.Live(null, "s2"), SessionSlot.adopt(free, null, "s2"))
    }

    @Test
    fun freeIgnoresTheEventsOfSessionsItDoesNotHold() {
        for (event in listOf(
            SlotEvent.Ending, SlotEvent.TeardownDone, SlotEvent.TeardownSlow,
            SlotEvent.Ended, SlotEvent.Cancelled,
        )) {
            assertEquals(SlotStep(free, emptyList()), SessionSlot.transition(free, event))
        }
    }

    @Test
    fun theSamePinnedMacHandsItsSessionOver() {
        assertEquals(
            SlotStep(
                SlotState.Handing(old = "s1", oldMac = "aa", newMac = "aa"),
                listOf(SlotAction.DROP_OLD, SlotAction.AWAIT_TEARDOWN),
            ),
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
    fun aLiveSessionThatCanNoLongerServeDrainsAndKeepsItsSession() {
        assertEquals(
            SlotStep(SlotState.Draining("aa", "s1"), emptyList()),
            SessionSlot.transition(live, SlotEvent.Ending),
        )
        assertEquals(
            SlotStep(SlotState.Draining(null, "s1"), emptyList()),
            SessionSlot.transition(SlotState.Live(null, "s1"), SlotEvent.Ending),
        )
    }

    @Test
    fun aLiveSlotIgnoresTeardownsOfSessionsItIsNotWaitingFor() {
        for (event in listOf(SlotEvent.TeardownDone, SlotEvent.TeardownSlow)) {
            assertEquals(SlotStep(live, emptyList()), SessionSlot.transition(live, event))
        }
    }

    @Test
    fun aLiveSlotIsFreedByItsOwnEndOrByADrop() {
        for (event in listOf(SlotEvent.Ended, SlotEvent.Cancelled)) {
            assertEquals(SlotStep(free, emptyList()), SessionSlot.transition(live, event))
        }
    }

    @Test
    fun anyMacWaitsForADrainingTeardownInsteadOfHearingBusy() {
        for (same in listOf(false, true)) {
            val connect = SlotEvent.Connect(if (same) "aa" else "bb", same)
            assertEquals(
                SlotStep(
                    SlotState.Handing(old = "s1", oldMac = "aa", newMac = connect.peerMac),
                    listOf(SlotAction.DROP_OLD, SlotAction.AWAIT_TEARDOWN),
                ),
                SessionSlot.transition(draining, connect),
            )
        }
    }

    @Test
    fun aDrainingSlotIsFreedByItsEndOrByADrop() {
        for (event in listOf(SlotEvent.Ended, SlotEvent.Cancelled)) {
            assertEquals(SlotStep(free, emptyList()), SessionSlot.transition(draining, event))
        }
        for (event in listOf(SlotEvent.Ending, SlotEvent.TeardownDone, SlotEvent.TeardownSlow)) {
            assertEquals(SlotStep(draining, emptyList()), SessionSlot.transition(draining, event))
        }
    }

    @Test
    fun aFinishedTeardownLeavesTheSlotFreeForTheWaitingMac() {
        assertEquals(SlotStep(free, emptyList()), SessionSlot.transition(handing, SlotEvent.TeardownDone))
    }

    @Test
    fun aSlowTeardownLeavesTheOldSessionInTheSlot() {
        // Not busy-forever: the old session keeps the slot (it is still
        // draining) and its own end frees it.
        assertEquals(
            SlotStep(SlotState.Live("aa", "s1"), listOf(SlotAction.BUSY_SLOW)),
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
    fun aRunningHandoverIgnoresTheOldSessionsOwnEndAndADropFreesIt() {
        // Its own end is the latch the waiter is on, never a second transition.
        for (event in listOf(SlotEvent.Ending, SlotEvent.Ended)) {
            assertEquals(SlotStep(handing, emptyList()), SessionSlot.transition(handing, event))
        }
        // A drop always frees the slot, whatever was handing.
        assertEquals(SlotStep(free, emptyList()), SessionSlot.transition(handing, SlotEvent.Cancelled))
    }

    @Test
    fun aJoinWithNothingToAttachToOnlyTellsThePinnedMac() {
        // PATH-3/11: only a certificate this phone pins learns `no_session`;
        // every stranger still gets today's `busy`.
        val pinned = SlotEvent.Connect("aa", samePinnedMac = false, join = true, pinned = true)
        assertEquals(SlotStep(free, listOf(SlotAction.NO_SESSION)), SessionSlot.transition(free, pinned))
        val stranger = SlotEvent.Connect("bb", samePinnedMac = false, join = true, pinned = false)
        assertEquals(SlotStep(free, listOf(SlotAction.BUSY)), SessionSlot.transition(free, stranger))
    }

    @Test
    fun aJoinForTheLiveSessionAttachesWithoutSupersedingIt() {
        // PATH-3: the same Mac, the live session's id: one more path, no drop.
        val join = SlotEvent.Connect("aa", samePinnedMac = true, join = true, joinMatches = true, pinned = true)
        assertEquals(SlotStep(live, listOf(SlotAction.JOIN)), SessionSlot.transition(live, join))
    }

    @Test
    fun aJoinForAnotherSessionIdIsNoSessionOnlyForTheLiveMac() {
        val stale = SlotEvent.Connect("aa", samePinnedMac = true, join = true, joinMatches = false, pinned = true)
        assertEquals(SlotStep(live, listOf(SlotAction.NO_SESSION)), SessionSlot.transition(live, stale))
        val stranger = SlotEvent.Connect("bb", samePinnedMac = false, join = true, joinMatches = false, pinned = true)
        assertEquals(SlotStep(live, listOf(SlotAction.BUSY)), SessionSlot.transition(live, stranger))
    }

    @Test
    fun aJoinDuringATeardownFindsNoSession() {
        // PATH-3: a draining session is over; its own Mac hears no_session.
        val join = SlotEvent.Connect("aa", samePinnedMac = true, join = true, joinMatches = true, pinned = true)
        assertEquals(SlotStep(draining, listOf(SlotAction.NO_SESSION)), SessionSlot.transition(draining, join))
        val stranger = SlotEvent.Connect("bb", samePinnedMac = false, join = true, pinned = false)
        assertEquals(SlotStep(draining, listOf(SlotAction.BUSY)), SessionSlot.transition(draining, stranger))
        // One hand-over at a time, and a join never starts another.
        val handingJoin = SlotEvent.Connect("aa", samePinnedMac = true, join = true, joinMatches = true, pinned = true)
        assertEquals(SlotStep(handing, listOf(SlotAction.BUSY)), SessionSlot.transition(handing, handingJoin))
    }

    @Test
    fun everyDescriptionIsAClosedToken() {
        assertEquals(
            setOf("free", "live", "draining", "handing"),
            listOf(free, live, draining, handing).map(SessionSlot::describe).toSet(),
        )
        assertEquals(
            setOf(
                "connect(same mac)", "connect(other mac)", "join(own session)",
                "join(other session)", "ending", "teardown done", "teardown slow", "ended",
                "cancelled",
            ),
            listOf(
                SlotEvent.Connect("aa", true), SlotEvent.Connect("bb", false),
                SlotEvent.Connect("aa", true, join = true, joinMatches = true),
                SlotEvent.Connect("aa", true, join = true, joinMatches = false),
                SlotEvent.Ending, SlotEvent.TeardownDone, SlotEvent.TeardownSlow, SlotEvent.Ended,
                SlotEvent.Cancelled,
            ).map(SessionSlot::describe).toSet(),
        )
    }

    @Test
    fun theSameSessionIsCarriedAcrossEveryState() {
        // One value owns the phone from Live to Draining to Handing to its end.
        val stepping = SessionSlot.transition(live, SlotEvent.Ending).next
        assertEquals("s1", (stepping as SlotState.Draining).session)
        val handingStep = SessionSlot.transition(stepping, SlotEvent.Connect("bb", false)).next
        assertEquals("s1", (handingStep as SlotState.Handing).old)
        assertEquals(SlotState.Live("bb", "s2"), SessionSlot.adopt(SlotState.Free, "bb", "s2"))
    }
}
