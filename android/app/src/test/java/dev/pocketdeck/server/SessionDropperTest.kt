package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
    private fun SessionDropper.adopting(session: LiveSession) = adopt(null, false) { session }

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
    fun aDropWithNoSessionDropsNothing() {
        assertFalse(SessionDropper(log = {}, closer = DIRECT).drop())
    }

    // ------------------------------------------------------------------
    // PAIR-21: the same pinned Mac supersedes its own stale session
    // ------------------------------------------------------------------

    private val macA = "aa".repeat(32)
    private val macB = "bb".repeat(32)

    @Test
    fun theSamePinnedMacTakesOverTheSlotAtOnce() {
        val old = FakeLiveSession()
        val next = FakeLiveSession()
        val dropper = SessionDropper(log = {}, closer = behind())
        assertSame(old, dropper.adopt(macA, pinned = true) { old })

        val taken = java.util.concurrent.atomic.AtomicReference<LiveSession?>()
        val started = System.nanoTime()
        val worker = thread { taken.set(dropper.adopt(macA, pinned = true) { next }) }
        assertTrue("the old session was never closed", old.closeStarted.await(1, TimeUnit.SECONDS))
        dropper.finished(old) // the old run returned, as Server's session thread does
        worker.join(2_000)
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertSame("the same Mac was answered busy", next, taken.get())
        assertTrue("the hand-over waited ${elapsedMs}ms", elapsedMs < 2_000)
        assertSame(next, dropper.current())
    }

    @Test
    fun anUnpinnedPeerNeverSupersedes() {
        val old = FakeLiveSession()
        val dropper = SessionDropper(log = {}, closer = DIRECT)
        dropper.adopt(macA, pinned = true) { old }
        assertNull(
            "an unpinned connection replaced the live session",
            dropper.adopt(macA, pinned = false) { FakeLiveSession() },
        )
        assertSame(old, dropper.current())
    }

    @Test
    fun aDifferentMacIsBusyWhileTheHandoverRuns() {
        val gate = CountDownLatch(1)
        val old = FakeLiveSession(gate)
        val dropper = SessionDropper(log = {}, closer = behind(), handoffWaitMs = 2_000)
        dropper.adopt(macA, pinned = true) { old }

        val handed = java.util.concurrent.atomic.AtomicReference<LiveSession?>()
        val worker = thread { handed.set(dropper.adopt(macA, pinned = true) { FakeLiveSession() }) }
        assertTrue("the old close never started", old.closeStarted.await(1, TimeUnit.SECONDS))
        assertNull(
            "a different Mac joined a running hand-over",
            dropper.adopt(macB, pinned = true) { FakeLiveSession() },
        )
        assertNull(
            "the same Mac joined a running hand-over twice",
            dropper.adopt(macA, pinned = true) { FakeLiveSession() },
        )

        gate.countDown()
        assertTrue(old.awaitClosed())
        dropper.finished(old)
        worker.join(3_000)
        assertNotNull("the waiting Mac was never adopted", handed.get())
    }

    @Test
    fun aTeardownPastTheBoundAnswersBusyAndSaysSo() {
        val gate = CountDownLatch(1)
        val old = FakeLiveSession(gate)
        val lines = java.util.Collections.synchronizedList(mutableListOf<String>())
        val dropper = SessionDropper(log = { lines.add(it) }, closer = behind(), handoffWaitMs = 200)
        dropper.adopt(macA, pinned = true) { old }

        assertNull(
            "a session was adopted over a running teardown",
            dropper.adopt(macA, pinned = true) { FakeLiveSession() },
        )
        assertTrue(
            "no line said the hand-over gave up: $lines",
            lines.any { it.startsWith("session supersede gave up") },
        )
        // The old session keeps the slot until its own teardown ends; a session
        // that is closed never serves.
        gate.countDown()
        assertTrue(old.awaitClosed())
        assertEquals(null, dropper.current())
        dropper.finished(old)
        val next = FakeLiveSession()
        assertSame("the closed session's end did not free the slot", next, dropper.adopt(macA, pinned = true) { next })
    }

    // ------------------------------------------------------------------
    // PAIR-21: a slow teardown must never wedge the slot
    // ------------------------------------------------------------------

    @Test
    fun aSlowTeardownsOldSessionFinishingFreesTheSlotForItsOwnMac() {
        val gate = CountDownLatch(1)
        val old = FakeLiveSession(gate)
        val dropper = SessionDropper(log = {}, closer = behind(), handoffWaitMs = 150)
        dropper.adopt(macA, pinned = true) { old }
        assertNull("the gated teardown did not answer busy", dropper.adopt(macA, pinned = true) { FakeLiveSession() })

        gate.countDown()
        assertTrue(old.awaitClosed())
        dropper.finished(old)

        val next = FakeLiveSession()
        assertSame("the slot did not free after the teardown", next, dropper.adopt(macA, pinned = true) { next })
        assertSame(next, dropper.current())
    }

    @Test
    fun aSlowTeardownsOldSessionFinishingFreesTheSlotForAnotherMac() {
        val gate = CountDownLatch(1)
        val old = FakeLiveSession(gate)
        val dropper = SessionDropper(log = {}, closer = behind(), handoffWaitMs = 150)
        dropper.adopt(macA, pinned = true) { old }
        assertNull("the gated teardown did not answer busy", dropper.adopt(macA, pinned = true) { FakeLiveSession() })

        gate.countDown()
        assertTrue(old.awaitClosed())
        dropper.finished(old)

        // The slot is free: a pairing peer, not only the old Mac, is adopted.
        val next = FakeLiveSession()
        assertSame("another Mac was not adopted on a free slot", next, dropper.adopt(macB, pinned = false) { next })
        assertSame(next, dropper.current())
    }

    @Test
    fun aSlowTeardownThenAConnectThatWaitsIsAdoptedWhenTheTeardownEnds() {
        val gate = CountDownLatch(1)
        val old = FakeLiveSession(gate)
        val dropper = SessionDropper(log = {}, closer = behind(), handoffWaitMs = 2_000)
        dropper.adopt(macA, pinned = true) { old }
        assertNull("the gated teardown did not answer busy", dropper.adopt(macA, pinned = true) { FakeLiveSession() })

        val taken = java.util.concurrent.atomic.AtomicReference<LiveSession?>()
        val worker = thread { taken.set(dropper.adopt(macA, pinned = true) { FakeLiveSession() }) }
        Thread.sleep(100) // real-time: the second connect must be inside its wait
        gate.countDown()
        assertTrue(old.awaitClosed())
        dropper.finished(old)
        worker.join(3_000)

        assertNotNull("the waiting Mac was not adopted when the teardown ended", taken.get())
        assertSame(taken.get(), dropper.current())
    }

    @Test
    fun aSlowTeardownThenADropFreesTheSlotForTheNextMac() {
        val gate = CountDownLatch(1)
        val old = FakeLiveSession(gate)
        val dropper = SessionDropper(log = {}, closer = behind(), handoffWaitMs = 150)
        dropper.adopt(macA, pinned = true) { old }
        assertNull("the gated teardown did not answer busy", dropper.adopt(macA, pinned = true) { FakeLiveSession() })

        assertTrue("a slow teardown left nothing to drop", dropper.drop())
        gate.countDown()
        assertTrue(old.awaitClosed())
        dropper.finished(old)

        val next = FakeLiveSession()
        assertSame("the slot did not free after a drop", next, dropper.adopt(macA, pinned = true) { next })
        assertSame(next, dropper.current())
    }

    @Test
    fun everyInterleavingEndsFreeWithTheNextMacAdopted() {
        val plans = listOf(
            listOf("adopt", "slow", "finish"),
            listOf("adopt", "slow", "drop"),
            listOf("adopt", "slow", "finish", "adopt", "finish"),
            listOf("adopt", "slow", "finish", "drop"),
            listOf("adopt", "finish"),
            listOf("adopt", "drop"),
            listOf("adopt", "slow", "finish", "adopt", "drop"),
        )
        for (plan in plans) runInterleaving(plan)
    }

    /** One plan of the sequence test: every old session is finished at the end. */
    private fun runInterleaving(plan: List<String>) {
        val gate = CountDownLatch(1)
        val dropper = SessionDropper(log = {}, closer = behind(), handoffWaitMs = 120)
        val sessions = mutableListOf<FakeLiveSession>()
        fun adopt(): LiveSession? {
            val session = FakeLiveSession(gate)
            sessions.add(session)
            return dropper.adopt(macA, pinned = true) { session }
        }
        fun release() {
            gate.countDown()
            sessions.forEach { it.awaitClosed() }
            sessions.forEach { dropper.finished(it) }
        }
        for (step in plan) {
            when (step) {
                "adopt" -> assertNotNull("$plan: an adopt on a free slot was refused", adopt())
                "slow" -> assertNull("$plan: a gated teardown answered a session", adopt())
                "finish" -> release()
                "drop" -> dropper.drop()
                else -> error("unknown step $step")
            }
        }
        release() // every old session finished before the last connect
        val next = FakeLiveSession()
        assertSame("$plan: the next Mac was not adopted", next, dropper.adopt(macB, pinned = false) { next })
        assertSame("$plan: the slot does not hold the new session", next, dropper.current())
    }

    @Test
    fun theNewSessionIsCreatedOnlyAfterTheOldTeardownFinished() {
        val order = java.util.Collections.synchronizedList(mutableListOf<String>())
        val old = FakeLiveSession()
        val dropper = SessionDropper(log = {}, closer = DIRECT, handoffWaitMs = 2_000)
        dropper.adopt(macA, pinned = true) { old }

        thread {
            Thread.sleep(150) // real-time: the old teardown is another thread's
            order.add("teardown")
            dropper.finished(old)
        }
        val created = dropper.adopt(macA, pinned = true) {
            order.add("created")
            FakeLiveSession()
        }

        assertNotNull(created)
        assertEquals(listOf("teardown", "created"), order)
    }

    @Test
    fun aDropDuringAHandoverCancelsIt() {
        val gate = CountDownLatch(1)
        val old = FakeLiveSession(gate)
        val dropper = SessionDropper(log = {}, closer = behind(), handoffWaitMs = 2_000)
        dropper.adopt(macA, pinned = true) { old }

        val handed = java.util.concurrent.atomic.AtomicReference<LiveSession?>()
        val worker = thread { handed.set(dropper.adopt(macA, pinned = true) { FakeLiveSession() }) }
        assertTrue(old.closeStarted.await(1, TimeUnit.SECONDS))
        assertTrue("a hand-over had nothing to drop", dropper.drop())
        worker.join(3_000)
        assertNull("the new Mac was adopted after every session was dropped", handed.get())
        gate.countDown()
    }

    /**
     * ISS-13: a drop frees the slot at once, so the next session can listen
     * before the dropped one's teardown reaches its clipboard stop.
     */
    @Test
    fun aDroppedSessionsLateClipboardStopDoesNotSilenceTheNextSession() {
        val platform = FakePlatform()
        val stopEntered = CountDownLatch(1)
        val release = CountDownLatch(1)
        platform.onClipStop = {
            stopEntered.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        val old = FakeLiveSession(onClosed = { platform.stop() })
        val dropper = SessionDropper(log = {}, closer = behind())
        dropper.adopt(macA, pinned = true) { old }
        platform.listen { } // the old session's sync
        assertTrue("a live session was not dropped", dropper.drop())
        assertTrue("the dropped session never reached its clipboard stop",
            stopEntered.await(1, TimeUnit.SECONDS))

        val next = FakeLiveSession()
        assertSame(next, dropper.adopt(macA, pinned = true) { next })
        val heard = java.util.concurrent.atomic.AtomicInteger(0)
        platform.listen { heard.incrementAndGet() } // the new session's sync

        release.countDown()
        awaitTrue("the dropped session's stop never finished") { platform.clipStopsDone.get() == 1 }
        platform.changeClip("after the hand-over")

        assertEquals("the new session lost its listener to the dropped one", 1, heard.get())
    }

    @Test
    fun aClosedSessionsTeardownStillOwnsTheSlot() {
        val dead = FakeLiveSession()
        dead.close()
        val next = FakeLiveSession()
        val dropper = SessionDropper(log = {}, closer = DIRECT, handoffWaitMs = 2_000)
        dropper.adopt(macB, pinned = true) { dead }
        assertNull("a closed session still serves", dropper.current())

        val taken = java.util.concurrent.atomic.AtomicReference<LiveSession?>()
        val worker = thread { taken.set(dropper.adopt(macB, pinned = true) { next }) }
        thread {
            Thread.sleep(100) // real-time: the hand-over must be waiting already
            dropper.finished(dead)
        }
        worker.join(2_000)
        assertSame("a closed session's teardown blocked the next Mac", next, taken.get())
    }

    /** An executor that runs the close on another thread, like the dropper's own. */
    private fun behind() = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "drop-test-behind").apply { isDaemon = true }
    }

    /** Polls [condition] for up to two seconds, then asserts it. */
    private fun awaitTrue(what: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 2_000
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(5) // real-time: the teardown runs on the dropper's own thread
        }
        assertTrue(what, condition())
    }

    private fun thread(work: () -> Unit): Thread = Thread(work).apply { isDaemon = true; start() }

    private companion object {
        /** Runs the close on the calling thread where the test already blocked it. */
        val DIRECT = java.util.concurrent.Executor { it.run() }
    }
}
