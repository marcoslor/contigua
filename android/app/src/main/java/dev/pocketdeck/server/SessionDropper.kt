package dev.pocketdeck.server

import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The one live session a [Server] serves, from the server's side
 * (docs/specs/pairing.md PAIR-20). It is a port, not a session type: the server's
 * single-session rule, its drops and its pushes all go through these members, and
 * a test can hold a session whose close blocks.
 */
interface LiveSession {
    /** True once the session is gone: no byte can be served from it again. */
    val isClosed: Boolean

    /** Authenticated and open: a share may go out. */
    val isReady: Boolean

    fun close()

    fun shareText(text: String): Int

    fun shareFile(name: String, mime: String, input: InputStream): Int

    fun listenerAccessChanged(granted: Boolean)

    fun onDeviceEvent(t: String, obj: Map<String, Any?>)

    fun applyGates()

    fun respondPairing(requestId: String, allow: Boolean)
}

/**
 * The live session of one server and the one daemon thread that ends it. A drop
 * is a hand-off, never a wait: the caller can be the binder thread serving the
 * app's push — the app's UI thread for Forget All — and the platform TLS close
 * can wait on a peer that stopped reading (docs/specs/pairing.md PAIR-20).
 *
 * The slot itself is [SessionSlot]'s machine (PAIR-21): the same pinned Mac
 * coming back drops its own stale session and is adopted once that session's
 * teardown — which releases the phone's displays, the panel hold, streams and
 * the notify and clip gates — has finished, waiting at most [handoffWaitMs].
 */
class SessionDropper(
    private val log: (String) -> Unit = {},
    private val closer: Executor = daemonThread(),
    /** The bound on a hand-over's wait for the old teardown (PAIR-21). */
    private val handoffWaitMs: Long = HANDOFF_WAIT_MS,
) {
    private val lock = Any()
    private var slot: SlotState = SlotState.Free
    private var live: LiveSession? = null
    private var handoff: Handoff? = null

    /** The old session of a running hand-over and the latch its teardown opens. */
    private class Handoff(val old: LiveSession, val latch: CountDownLatch)

    /** The live session, if one is neither closed nor already dropped. */
    fun current(): LiveSession? = synchronized(lock) { live?.takeIf { !it.isClosed } }

    /**
     * Runs [create] only when the slot takes the connecting Mac, so the
     * "one session at a time" decision and the session's creation cannot race.
     *
     * [peerMac] is the connecting Mac's TLS fingerprint hex (null when the
     * socket cannot report one) and [pinned] says the phone pins it. Null means
     * the Mac is answered `busy`: a live session of a different Mac, of an
     * unpinned or pairing peer, or a teardown that outlived the bound.
     */
    fun <T : LiveSession> adopt(peerMac: String?, pinned: Boolean, create: () -> T): T? {
        val old: Handoff = synchronized(lock) {
            // A session that can serve nothing more is draining: its teardown
            // still owns the phone's shared state until it ends.
            if (slot is SlotState.Live && live?.isClosed != false) step(SlotEvent.Ending)
            val current = slot as? SlotState.Live
            val same = pinned && peerMac != null &&
                current?.mac?.equals(peerMac, ignoreCase = true) == true
            val moved = step(SlotEvent.Connect(peerMac ?: "", same))
            when {
                moved.actions.contains(SlotAction.ADOPT) -> {
                    return create().also { live = it }
                }
                moved.actions.contains(SlotAction.BUSY) -> return null
                else -> {
                    log("session superseded")
                    // The waiting Mac's session starts only after the old teardown.
                    val dropped = live
                    live = null
                    val begun = Handoff(dropped ?: return null, CountDownLatch(1))
                    handoff = begun
                    begun
                }
            }
        }
        // The close is a hand-off (PAIR-20); the wait below is the ordering rule.
        dropOnOwnThread(old.old)
        val done = old.latch.await(handoffWaitMs, TimeUnit.MILLISECONDS)
        synchronized(lock) {
            // A drop or another hand-over took the slot while we waited.
            if (handoff !== old) return null
            handoff = null
            val moved = step(if (done) SlotEvent.TeardownDone else SlotEvent.TeardownSlow)
            if (!moved.actions.contains(SlotAction.ADOPT)) {
                log("session supersede gave up: teardown not done in ${handoffWaitMs}ms")
                return null
            }
            return create().also { live = it }
        }
    }

    /** The session's own run ended: free the slot for the next Mac. */
    fun finished(session: LiveSession) = synchronized(lock) {
        if (live === session) {
            live = null
            step(SlotEvent.Ended)
        }
        val waiting = handoff
        if (waiting != null && waiting.old === session) waiting.latch.countDown()
    }

    /** Drops the live session without waiting; true when there was one. */
    fun drop(): Boolean {
        val session = synchronized(lock) {
            val current = live
            val waiting = handoff
            if (current == null && waiting == null) return false
            live = null
            handoff = null
            if (slot is SlotState.Handing) {
                // A hand-over waiting on a session that must go now: the Mac that
                // was about to be adopted is answered busy instead.
                log("session slot: handing --dropped--> free")
                slot = SlotState.Free
            } else if (current != null) {
                step(SlotEvent.Ended)
            }
            waiting?.latch?.countDown()
            current
        }
        if (session != null) dropOnOwnThread(session)
        return true
    }

    /** Runs one transition of the slot machine and logs it. The lock is held. */
    private fun step(event: SlotEvent): SlotStep {
        val from = slot
        val next = SessionSlot.transition(from, event)
        slot = next.next
        if (next.next != from) {
            log("session slot: ${SessionSlot.describe(from)} --${SessionSlot.describe(event)}--> ${SessionSlot.describe(next.next)}")
        }
        return next
    }

    private fun dropOnOwnThread(session: LiveSession) {
        closer.execute {
            runCatching { session.close() }.onFailure {
                // Class only: never a message that could carry an address.
                log("session close failed: ${it.javaClass.simpleName}")
            }
        }
    }

    companion object {
        /**
         * The hand-over bound (PAIR-21): the old session's teardown normally
         * ends in well under a second; a slower one is answered `busy` so the
         * phone never opens a second session over the shared state.
         */
        const val HANDOFF_WAIT_MS = 2_000L

        /** One daemon for every drop: a stuck TLS close must never cost a thread. */
        private fun daemonThread(): Executor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "pocketdeck-session-drop").apply { isDaemon = true }
        }
    }
}
