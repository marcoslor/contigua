package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The one-session slot and its drop hand-off (docs/specs/pairing.md PAIR-20):
 * the caller — a binder thread serving the app's push, the app's UI thread for
 * Forget All — must never wait for a session's close.
 */
class SessionDropperTest {

    /** Adopts [session] as the live one. */
    private fun SessionDropper.adopting(session: LiveSession) = adopt { session }

    @Test
    fun aDropReturnsAtOnceEvenWhenTheCloseBlocks() {
        val session = FakeLiveSession(CountDownLatch(1))
        val dropper = SessionDropper(log = {})
        dropper.adopting(session)

        val started = System.nanoTime()
        assertTrue("a live session was not dropped", dropper.drop())
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertTrue("the drop waited ${elapsedMs}ms for the close", elapsedMs < 100)
        assertNull("the dropped session is still active", dropper.current())
        assertTrue("the close never ran", session.closeStarted.await(1, TimeUnit.SECONDS))
        assertEquals("the close did not wait for the block", false, session.closed)
        session.release()
    }

    @Test
    fun theCloseRunsOnTheDroppersOwnThread() {
        val pool = Executors.newSingleThreadExecutor { r ->
            Thread(r, "drop-test-thread").apply { isDaemon = true }
        }
        val session = FakeLiveSession()
        val dropper = SessionDropper(log = {}, closer = pool)
        dropper.adopting(session)

        assertTrue(dropper.drop())
        assertTrue("the close never ran", session.closeStarted.await(1, TimeUnit.SECONDS))
        assertTrue(session.awaitClosed())
        assertEquals("drop-test-thread", session.closedOn)
        pool.shutdownNow()
    }

    @Test
    fun aSecondMacIsRefusedWhileASessionIsLive() {
        val first = FakeLiveSession()
        val second = FakeLiveSession()
        val dropper = SessionDropper(log = {}, closer = DIRECT)
        assertSame(first, dropper.adopting(first))
        assertNull("a second session was adopted over a live one", dropper.adopting(second))
        assertSame(first, dropper.current())
    }

    @Test
    fun aFinishedSessionFreesTheSlotForTheNextMac() {
        val first = FakeLiveSession()
        val second = FakeLiveSession()
        val dropper = SessionDropper(log = {}, closer = DIRECT)
        dropper.adopting(first)
        dropper.finished(first)
        assertNull(dropper.current())
        assertSame(second, dropper.adopting(second))
    }

    @Test
    fun anAlreadyClosedSessionIsReplaced() {
        val dead = FakeLiveSession()
        dead.close()
        val next = FakeLiveSession()
        val dropper = SessionDropper(log = {}, closer = DIRECT)
        dropper.adopting(dead)
        assertNull("a closed session still holds the slot", dropper.current())
        assertSame(next, dropper.adopting(next))
    }

    @Test
    fun aDropWithNoSessionDropsNothing() {
        assertFalse(SessionDropper(log = {}, closer = DIRECT).drop())
    }

    private companion object {
        /** Runs the close on the calling thread where the test already blocked it. */
        val DIRECT = java.util.concurrent.Executor { it.run() }
    }
}
