package dev.pocketdeck.server

import java.io.InputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors

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
 */
class SessionDropper(
    private val log: (String) -> Unit = {},
    private val closer: Executor = daemonThread(),
) {
    private val lock = Any()
    private var live: LiveSession? = null

    /** The live session, if one is neither closed nor already dropped. */
    fun current(): LiveSession? = synchronized(lock) { live?.takeIf { !it.isClosed } }

    /**
     * Runs [create] only while no live session is there and adopts its result,
     * so the "one session at a time" decision and the session's creation cannot
     * race. Null means a live session is already running (answer `busy`).
     */
    fun <T : LiveSession> adopt(create: () -> T): T? = synchronized(lock) {
        if (live?.isClosed == false) return null
        create().also { live = it }
    }

    /** The session's own run ended: free the slot for the next Mac. */
    fun finished(session: LiveSession) = synchronized(lock) {
        if (live === session) live = null
    }

    /** Drops the live session without waiting; true when there was one. */
    fun drop(): Boolean {
        val session = synchronized(lock) { live.also { live = null } } ?: return false
        closer.execute {
            runCatching { session.close() }.onFailure {
                // Class only: never a message that could carry an address.
                log("session close failed: ${it.javaClass.simpleName}")
            }
        }
        return true
    }

    private companion object {
        /** One daemon for every drop: a stuck TLS close must never cost a thread. */
        fun daemonThread(): Executor = Executors.newSingleThreadExecutor { r ->
            Thread(r, "pocketdeck-session-drop").apply { isDaemon = true }
        }
    }
}
