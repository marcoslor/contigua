package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wake-ownership rule (docs/specs/controls.md CTRL-7): the phone is put
 * back to sleep after the last stream only while PocketDeck's own wake still
 * owns it, and the person's own use is read as edges. Every state accepts every
 * event; the ignored ones are tested as ignored.
 */
class WakeOwnershipTest {

    private fun step(state: WakeState, event: WakeEvent) = wakeTransition(state, event)

    private fun woke(nowMs: Long = 1_000L) = step(WakeState(), WakeEvent.OurWake(nowMs)).state

    // MARK: The reported bug's own transition

    @Test
    fun `last stream close after the person unlocked does not sleep the phone`() {
        // The real log: PocketDeck woke the panel's group for a stream, the
        // person unlocked and used the phone 21 s before the last Mac window
        // closed, and the close slept the screen under their hands.
        val unlocked = step(woke(), WakeEvent.PersonUnlocked)
        assertEquals(WakeOwner.PERSON_TOOK_OVER, unlocked.state.owner)

        val close = step(unlocked.state, WakeEvent.StreamsStopped)
        assertTrue("the close must not sleep a phone the person has", close.actions.isEmpty())
        assertEquals(WakeCloseReason.PERSON_UNLOCKED, close.closeReason)
        assertEquals(WakeOwner.NOT_OURS, close.state.owner)
    }

    @Test
    fun `last stream close while the wake is still ours sleeps the phone`() {
        val close = step(woke(), WakeEvent.StreamsStopped)
        assertEquals(listOf(WakeAction.SLEEP_PHONE), close.actions)
        assertNull(close.closeReason)
        assertEquals(WakeOwner.NOT_OURS, close.state.owner)
    }

    // MARK: NotOurs

    @Test
    fun `our wake takes ownership`() {
        val next = step(WakeState(), WakeEvent.OurWake(1_000L))
        assertEquals(WakeOwner.OURS_WOKE, next.state.owner)
        assertEquals(1_000L + WAKE_OWN_SETTLE_MS, next.state.ownUntilMs)
        assertTrue(next.actions.isEmpty())
    }

    @Test
    fun `a person's use before any wake changes nothing`() {
        val unlocked = step(WakeState(), WakeEvent.PersonUnlocked)
        assertEquals(WakeOwner.NOT_OURS, unlocked.state.owner)
        assertTrue(unlocked.state.screenOn)

        val on = step(WakeState(), WakeEvent.ScreenReported(on = true, nowMs = 5_000L))
        assertEquals(WakeOwner.NOT_OURS, on.state.owner)
        assertTrue(on.state.screenOn)
        assertTrue(on.actions.isEmpty())
    }

    @Test
    fun `a close with nothing of ours does nothing`() {
        val close = step(WakeState(screenOn = true), WakeEvent.StreamsStopped)
        assertTrue(close.actions.isEmpty())
        assertNull(close.closeReason)
    }

    // MARK: OursWoke

    @Test
    fun `a second own wake keeps ownership and moves the baseline`() {
        val first = woke(1_000L)
        val second = step(first, WakeEvent.OurWake(9_000L))
        assertEquals(WakeOwner.OURS_WOKE, second.state.owner)
        assertEquals(9_000L + WAKE_OWN_SETTLE_MS, second.state.ownUntilMs)
    }

    @Test
    fun `our own wake's screen-on edge is not the person`() {
        // The platform reports the screen on a few hundred ms after our wake.
        val next = step(woke(1_000L), WakeEvent.ScreenReported(on = true, nowMs = 1_600L))
        assertEquals(WakeOwner.OURS_WOKE, next.state.owner)
        assertNull(next.state.reason)
        assertTrue(next.state.screenOn)
    }

    @Test
    fun `a screen-on edge after our settle is the person waking it`() {
        val next = step(woke(1_000L), WakeEvent.ScreenReported(on = true, nowMs = 9_000L))
        assertEquals(WakeOwner.PERSON_TOOK_OVER, next.state.owner)
        assertEquals(WakeCloseReason.PERSON_ACTIVE, next.state.reason)
        assertTrue(next.actions.isEmpty())
    }

    @Test
    fun `a screen that was already on is not a wake`() {
        val state = woke().copy(screenOn = true)
        val next = step(state, WakeEvent.ScreenReported(on = true, nowMs = 9_000L))
        assertEquals(WakeOwner.OURS_WOKE, next.state.owner)
    }

    @Test
    fun `the screen going off keeps ownership`() {
        val state = woke().copy(screenOn = true)
        val next = step(state, WakeEvent.ScreenReported(on = false, nowMs = 9_000L))
        assertEquals(WakeOwner.OURS_WOKE, next.state.owner)
        assertTrue(!next.state.screenOn)
    }

    @Test
    fun `an unlock while ours hands the phone to the person`() {
        val next = step(woke(), WakeEvent.PersonUnlocked)
        assertEquals(WakeOwner.PERSON_TOOK_OVER, next.state.owner)
        assertEquals(WakeCloseReason.PERSON_UNLOCKED, next.state.reason)
        assertTrue(next.actions.isEmpty())
    }

    // MARK: PersonTookOver

    @Test
    fun `our own wake during a relight keeps the phone the person's`() {
        // 16:33:16: PocketDeck re-lit the group while the person owned the
        // phone, and the log said `person --ourWake--> ourswoke`; a later close
        // would then have slept their screen.
        val person = step(woke(), WakeEvent.PersonUnlocked).state
        val relit = step(person, WakeEvent.OurWake(20_000L))
        assertEquals(WakeOwner.PERSON_TOOK_OVER, relit.state.owner)
        assertEquals(WakeCloseReason.PERSON_UNLOCKED, relit.state.reason)
        assertEquals(20_000L + WAKE_OWN_SETTLE_MS, relit.state.ownUntilMs)
    }

    @Test
    fun `a touch on the panel owns the phone without an unlock`() {
        val used = step(woke(), WakeEvent.PersonUsed)
        assertEquals(WakeOwner.PERSON_TOOK_OVER, used.state.owner)
        assertEquals(WakeCloseReason.PERSON_ACTIVE, used.state.reason)
        assertTrue(used.state.screenOn)
        assertTrue(used.actions.isEmpty())

        val close = step(used.state, WakeEvent.StreamsStopped)
        assertTrue("the close must not sleep a phone the person touched", close.actions.isEmpty())
        assertEquals(WakeCloseReason.PERSON_ACTIVE, close.closeReason)
    }

    @Test
    fun `the phone going idle by itself ends the person's ownership`() {
        val person = step(woke(), WakeEvent.PersonUnlocked).state
        val idle = step(person, WakeEvent.PersonIdle)
        assertEquals(WakeOwner.NOT_OURS, idle.state.owner)
        assertNull(idle.state.reason)
        // The relight that follows names the panel's group again, and the close
        // after it may sleep the phone: the person left.
        val ours = step(idle.state, WakeEvent.OurWake(30_000L)).state
        assertEquals(WakeOwner.OURS_WOKE, ours.owner)
        assertEquals(listOf(WakeAction.SLEEP_PHONE), step(ours, WakeEvent.StreamsStopped).actions)
    }

    @Test
    fun `an idle edge without the person's ownership changes nothing`() {
        val ours = step(woke(), WakeEvent.PersonIdle).state
        assertEquals(WakeOwner.OURS_WOKE, ours.owner)
        assertEquals(WakeOwner.NOT_OURS, step(WakeState(), WakeEvent.PersonIdle).state.owner)
    }

    @Test
    fun `a person's use before our wake changes nothing in the machine`() {
        val idle = step(WakeState(), WakeEvent.PersonUsed)
        assertEquals(WakeOwner.NOT_OURS, idle.state.owner)
        assertTrue(idle.actions.isEmpty())
    }

    @Test
    fun `the person's use keeps the phone`() {
        val person = step(woke(), WakeEvent.PersonUnlocked).state
        assertEquals(WakeOwner.PERSON_TOOK_OVER, step(person, WakeEvent.PersonUnlocked).state.owner)
        assertEquals(
            WakeOwner.PERSON_TOOK_OVER,
            step(person, WakeEvent.ScreenReported(on = true, nowMs = 30_000L)).state.owner,
        )
    }

    @Test
    fun `a close after the person's use leaves the screen alone`() {
        val person = step(woke(), WakeEvent.ScreenReported(on = true, nowMs = 9_000L)).state
        val close = step(person, WakeEvent.StreamsStopped)
        assertTrue(close.actions.isEmpty())
        assertEquals(WakeCloseReason.PERSON_ACTIVE, close.closeReason)
        assertEquals(WakeOwner.NOT_OURS, close.state.owner)
    }

    @Test
    fun `a close after an unlock without a screen edge names the unlock`() {
        val person = step(woke(), WakeEvent.PersonUnlocked).state
        assertEquals(WakeCloseReason.PERSON_UNLOCKED, step(person, WakeEvent.StreamsStopped).closeReason)
    }

    @Test
    fun `a close resets the machine for the next episode`() {
        val closed = step(woke(1_000L), WakeEvent.StreamsStopped).state
        assertTrue(!closed.screenOn)
        assertEquals(0L, closed.ownUntilMs)
        assertNull(closed.reason)
        assertEquals(WakeOwner.NOT_OURS, closed.owner)
    }

    // MARK: The live machine

    @Test
    fun `the machine keeps the state and logs every ownership change`() {
        val lines = ArrayList<String>()
        val machine = WakeOwnershipMachine { lines.add(it) }
        assertEquals(WakeOwner.NOT_OURS, machine.owner())
        machine.dispatch(WakeEvent.OurWake(1_000L))
        assertEquals(WakeOwner.OURS_WOKE, machine.owner())
        machine.dispatch(WakeEvent.PersonUnlocked)
        assertEquals(WakeOwner.PERSON_TOOK_OVER, machine.owner())
        val close = machine.dispatch(WakeEvent.StreamsStopped)
        assertEquals(WakeOwner.NOT_OURS, machine.owner())
        assertTrue(close.actions.isEmpty())

        assertEquals(
            listOf(
                "wake: notours --ourWake--> ourswoke",
                "wake: ourswoke --unlocked--> person",
                "wake: person --stopped--> notours",
            ),
            lines,
        )
    }

    // MARK: The person's use, as edges (PersonUseTracker)

    private fun state(locked: Boolean = true, screen: ScreenState? = null) =
        DeviceState(locked = locked, battery = 55, charging = false, screen = screen)

    @Test
    fun `a repeated state is not a use`() {
        val tracker = PersonUseTracker()
        val off = state(screen = ScreenState.OFF)
        assertEquals(emptyList<PersonUse>(), tracker.note(off))
        assertEquals(emptyList<PersonUse>(), tracker.note(off))
    }

    @Test
    fun `the first screen reading is not an edge`() {
        // A reconnect must not read the phone's current picture as a new wake.
        val tracker = PersonUseTracker()
        assertEquals(emptyList<PersonUse>(), tracker.note(state(screen = ScreenState.ON)))
        assertEquals(listOf(PersonUse.SCREEN_OFF), tracker.note(state(screen = ScreenState.OFF)))
        assertEquals(listOf(PersonUse.SCREEN_ON), tracker.note(state(screen = ScreenState.ON)))
    }

    @Test
    fun `a state without a screen reading keeps the last one`() {
        val tracker = PersonUseTracker()
        tracker.note(state(screen = ScreenState.OFF))
        assertEquals(emptyList<PersonUse>(), tracker.note(state(screen = null)))
        assertEquals(listOf(PersonUse.SCREEN_ON), tracker.note(state(screen = ScreenState.ON)))
    }

    @Test
    fun `an unlock is one use`() {
        val tracker = PersonUseTracker()
        assertEquals(emptyList<PersonUse>(), tracker.note(state(locked = true)))
        assertEquals(listOf(PersonUse.UNLOCKED), tracker.note(state(locked = false)))
        assertEquals(emptyList<PersonUse>(), tracker.note(state(locked = false)))
        assertEquals(emptyList<PersonUse>(), tracker.note(state(locked = true)))
        assertEquals(listOf(PersonUse.UNLOCKED), tracker.note(state(locked = false)))
    }

    @Test
    fun `a phone with no lock is unlocked once`() {
        val tracker = PersonUseTracker()
        assertEquals(listOf(PersonUse.UNLOCKED), tracker.note(state(locked = false)))
        assertEquals(emptyList<PersonUse>(), tracker.note(state(locked = false)))
    }

    @Test
    fun `an unlock and a screen edge in one state are both uses`() {
        val tracker = PersonUseTracker()
        tracker.note(state(locked = true, screen = ScreenState.OFF))
        assertEquals(
            listOf(PersonUse.UNLOCKED, PersonUse.SCREEN_ON),
            tracker.note(state(locked = false, screen = ScreenState.ON)),
        )
    }
}
