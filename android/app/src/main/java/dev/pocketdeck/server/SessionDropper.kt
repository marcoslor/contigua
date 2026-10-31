package dev.pocketdeck.server

import java.io.InputStream
import java.net.Socket
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * The one live session a [Server] serves, from the server's side
 * (docs/specs/pairing.md PAIR-20). It is a port, not a session type: the server's
 * single-session rule, its drops and its pushes all go through these members, and
 * a test can hold a session whose close blocks.
 */
interface LiveSession {
    /** True once the session is gone: no byte can be served from it again. */
    val isClosed: Boolean

    /** This session's id after `welcome` (PATH-3); null before it. */
    val pathSessionId: String?

    /** Attaches a joined TLS socket as one more path of this session (PATH-3). */
    fun attachPath(pathId: String, socket: Socket, plain: Socket): AttachResult

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
 * The slot is [SessionSlot]'s machine (PAIR-21) and it is the only record of
 * which session owns the phone: the sessions live in the state (`Free` / `Live` /
 * `Draining` / `Handing`), so no second field can fall out of step with it. Every
 * exit of [adopt] leaves the state either free or holding a session. A hand-over
 * that gives up leaves the old session in the slot (`Live`) until its own
 * teardown ends; that teardown frees the slot. A drop always frees it.
 */
/** What a join asked for (PATH-3/11/13). */
enum class AttachResult { ATTACHED, NO_SESSION, TOO_MANY, BUSY }

class SessionDropper(
    private val log: (String) -> Unit = {},
    private val closer: Executor = daemonThread(),
    /** The bound on a hand-over's wait for the old teardown (PAIR-21). */
    private val handoffWaitMs: Long = HANDOFF_WAIT_MS,
) {
    private val lock = ReentrantLock()
    /** Signalled whenever the slot changes hands (a teardown ended, a drop). */
    private val changed = lock.newCondition()
    private var slot: SlotState<LiveSession> = SlotState.Free

    /**
     * The app's drops, an epoch rather than a state: a hand-over that is waiting
     * when the app drops everything answers busy instead of adopting, and the
     * slot itself is already `Free`.
     */
    private var drops = 0L

    /**
     * A join's admission (PATH-3/11): only the live session's own pinned Mac
     * attaches or hears `no_session`; every other peer is `busy`.
     */
    fun attach(
        peerMac: String?,
        pinned: Boolean,
        joinId: String,
        pathId: String,
        socket: Socket,
        plain: Socket,
    ): AttachResult = lock.withLock {
        val state = slot
        if (state is SlotState.Live && state.session.isClosed) step(SlotEvent.Ending)
        val live = slot as? SlotState.Live
        val same = pinned && peerMac != null && live?.mac?.equals(peerMac, ignoreCase = true) == true
        val joinMatches = live != null && live.session.pathSessionId == joinId
        val event = SlotEvent.Connect(
            peerMac = peerMac.orEmpty(),
            samePinnedMac = same,
            join = true,
            joinMatches = joinMatches,
            pinned = pinned,
        )
        when (step(event).actions.firstOrNull()) {
            SlotAction.JOIN -> (slot as SlotState.Live).session.attachPath(pathId, socket, plain)
            SlotAction.NO_SESSION -> AttachResult.NO_SESSION
            else -> AttachResult.BUSY
        }
    }

    /** The live session, if one is neither closed nor already dropped. */
    fun current(): LiveSession? = lock.withLock {
        (slot as? SlotState.Live)?.session?.takeIf { !it.isClosed }
    }

    /**
     * Runs [create] only when the slot takes the connecting Mac, so the
     * "one session at a time" decision and the session's creation cannot race.
     *
     * [peerMac] is the connecting Mac's TLS fingerprint hex (null when the
     * socket cannot report one) and [pinned] says the phone pins it. Null means
     * the Mac is answered `busy`: a live session of a different Mac, of an
     * unpinned or pairing peer, or a teardown that outlived the bound.
     */
    fun <T : LiveSession> adopt(peerMac: String?, pinned: Boolean, create: () -> T): T? =
        when (val admission = lock.withLock { admit(peerMac, pinned, create) }) {
            is Admission.Adopted -> admission.session
            Admission.Busy -> null
            is Admission.HandOver -> afterTeardown(admission, peerMac, pinned, create)
        }

    /** The session's own run ended: free the slot for the next Mac. */
    fun finished(session: LiveSession) {
        lock.withLock {
            when (val state = slot) {
                is SlotState.Live -> if (state.session === session) step(SlotEvent.Ended)
                is SlotState.Draining -> if (state.session === session) step(SlotEvent.Ended)
                is SlotState.Handing -> if (state.old === session) step(SlotEvent.TeardownDone)
                SlotState.Free -> Unit
            }
            changed.signalAll()
        }
    }

    /** Drops the live session without waiting; true when there was one. */
    fun drop(): Boolean {
        val session = lock.withLock {
            val state = slot
            if (state is SlotState.Free) return false
            drops++
            step(SlotEvent.Cancelled)
            // A waiter wakes to a free slot and a drop it must not adopt after.
            changed.signalAll()
            when (state) {
                is SlotState.Live -> state.session
                is SlotState.Draining -> state.session
                // The hand-over's old session is already closing.
                is SlotState.Handing -> null
                SlotState.Free -> null
            }
        }
        if (session != null) dropOnOwnThread(session)
        return true
    }

    /** What one locked admission decided. */
    private sealed interface Admission<out T> {
        data class Adopted<T>(val session: T) : Admission<T>
        data object Busy : Admission<Nothing>
        data class HandOver(val old: LiveSession, val epoch: Long) : Admission<Nothing>
    }

    /** One transition of the slot, decided under the lock. */
    private fun <T : LiveSession> admit(peerMac: String?, pinned: Boolean, create: () -> T): Admission<T> {
        // A session that can serve nothing more is draining, not live.
        val state = slot
        if (state is SlotState.Live && state.session.isClosed) step(SlotEvent.Ending)
        val live = slot as? SlotState.Live
        val same = pinned && peerMac != null && live?.mac?.equals(peerMac, ignoreCase = true) == true
        return when (step(SlotEvent.Connect(peerMac.orEmpty(), same, pinned = pinned)).actions.firstOrNull()) {
            SlotAction.ADOPT -> Admission.Adopted(adoptNow(peerMac, create()))
            SlotAction.DROP_OLD -> {
                log("session superseded")
                Admission.HandOver((slot as SlotState.Handing).old, drops)
            }
            else -> Admission.Busy
        }
    }

    /**
     * Waits (bounded) for the hand-over's old session to finish, then adopts the
     * connecting Mac on the freed slot. A drop during the wait cancels it: the
     * app vouches for nobody, and the slot it freed is left to a later connect.
     */
    private fun <T : LiveSession> afterTeardown(
        start: Admission.HandOver,
        peerMac: String?,
        pinned: Boolean,
        create: () -> T,
    ): T? {
        // Never under the lock: a close may block on the peer (PAIR-20).
        dropOnOwnThread(start.old)
        return lock.withLock {
            var leftNs = TimeUnit.MILLISECONDS.toNanos(handoffWaitMs)
            while (true) {
                val state = slot
                if (state !is SlotState.Handing || state.old !== start.old) break
                if (leftNs <= 0) {
                    step(SlotEvent.TeardownSlow)
                    log("session supersede gave up: teardown not done in ${handoffWaitMs}ms")
                    return@withLock null
                }
                leftNs = try {
                    changed.awaitNanos(leftNs)
                } catch (e: InterruptedException) {
                    // An interrupted waiter must not leave a hand-over running
                    // with nobody on it: the old session keeps the slot.
                    step(SlotEvent.TeardownSlow)
                    Thread.currentThread().interrupt()
                    return@withLock null
                }
            }
            // The app dropped everything while this Mac waited: it gets busy.
            if (drops != start.epoch) return@withLock null
            if (step(SlotEvent.Connect(peerMac.orEmpty(), samePinnedMac = false, pinned = pinned)).actions.firstOrNull() != SlotAction.ADOPT) {
                log("session supersede abandoned: the slot changed hands")
                return@withLock null
            }
            adoptNow(peerMac, create())
        }
    }

    /** Records the created session as the slot's live one (the ADOPT action). */
    private fun <T : LiveSession> adoptNow(mac: String?, session: T): T {
        val from = slot
        slot = SessionSlot.adopt(from, mac, session)
        log("session slot: ${SessionSlot.describe(from)} --adopted--> ${SessionSlot.describe(slot)}")
        return session
    }

    /** Runs one transition of the slot machine and logs it. The lock is held. */
    private fun step(event: SlotEvent): SlotStep<LiveSession> {
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
         * ends in well under a second; a slower one is answered `busy` and the
         * old session keeps the slot until its own teardown ends.
         */
        const val HANDOFF_WAIT_MS = 2_000L

        /** One daemon for every drop: a stuck TLS close must never cost a thread. */
        private fun daemonThread(): Executor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "pocketdeck-session-drop").apply { isDaemon = true }
        }
    }
}
