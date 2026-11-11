package app.contigua.server

import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * A live session for the drop rule (docs/specs/pairing.md PAIR-20): [close]
 * records that it started and then blocks until the test releases it, which is
 * how the JVM sees a close that waits on a peer.
 */
internal class FakeLiveSession(
    private val gate: CountDownLatch = CountDownLatch(0),
    private val sessionId: String? = null,
    /** Runs at the end of [close], as a session's shutdown does (ISS-13). */
    private val onClosed: (() -> Unit)? = null,
    override val macClientId: String? = null,
) : LiveSession {
    /** What happened on this session, in order (for the PAIR-30 notice-before-close rule). */
    val events = mutableListOf<String>()

    val forgottenNotice = CountDownLatch(1)
    val forgottenCount: Int get() = events.count { it == "forgotten" }
    val closeStarted = CountDownLatch(1)

    @Volatile
    var closed = false

    @Volatile
    var closedOn: String? = null

    override val isClosed: Boolean get() = closed

    override val isReady: Boolean get() = !closed

    override val pathSessionId: String? get() = sessionId

    /** What a join gets; [attachedPlain] records the socket it arrived on. */
    var attachResult: AttachResult = AttachResult.NO_SESSION

    @Volatile
    var attachedPlain: java.net.Socket? = null

    override fun attachPath(pathId: String, socket: java.net.Socket, plain: java.net.Socket): AttachResult {
        attachedPlain = plain
        return attachResult
    }

    override fun forgotten() {
        events.add("forgotten")
        forgottenNotice.countDown()
    }

    override fun close() {
        events.add("close")
        closeStarted.countDown()
        gate.await(10, TimeUnit.SECONDS)
        onClosed?.invoke()
        closedOn = Thread.currentThread().name
        closed = true
    }

    fun release() = gate.countDown()

    /** Waits (bounded) for the close to finish. */
    fun awaitClosed(): Boolean {
        repeat(100) {
            if (closed) return true
            Thread.sleep(10) // real-time: the close runs on the dropper's own thread
        }
        return false
    }

    override fun shareText(text: String): Int = ShareStatus.NO_SESSION

    override fun shareFile(name: String, mime: String, input: InputStream): Int =
        ShareStatus.NO_SESSION

    override fun listenerAccessChanged(granted: Boolean) {}

    override fun onDeviceEvent(t: String, obj: Map<String, Any?>) {}

    override fun applyGates() {}

    override fun respondPairing(requestId: String, allow: Boolean) {}
}
