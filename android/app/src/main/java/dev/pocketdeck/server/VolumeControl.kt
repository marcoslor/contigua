package dev.pocketdeck.server

import java.util.concurrent.atomic.AtomicBoolean

/**
 * STREAM_MUSIC's level (docs/PROTOCOL.md "Volume"): `state.volume` and the
 * Mac's `phone.volume`.
 *
 * The write is the platform's own volume call with no UI flag, clamped to the
 * stream's maximum first. Nothing else on the phone is touched.
 */
class VolumeControl(
    private val settings: VolumeSettings,
    private val log: (String) -> Unit = {},
    /**
     * Re-read interval while a session is up. A safety net, not the main
     * source: the platform listener may be unreachable from the server's UID
     * (the shell process gets no broadcasts on some builds).
     */
    private val pollIntervalMs: Long = 1_000,
) {

    /** The level the phone reports now; null when unreadable. */
    fun current(): Int? = settings.read()?.first

    /** The stream's maximum; null when unreadable. */
    fun max(): Int? = settings.read()?.second

    /** The level and maximum from one read; null when unreadable. */
    fun read(): Pair<Int, Int>? = settings.read()

    /** Clamps [level] into 0…max and writes it; false when unreadable or refused. */
    @Synchronized
    fun apply(level: Int): Boolean {
        val (now, max) = settings.read() ?: run {
            log("volume: unreadable; left alone")
            return false
        }
        val wanted = level.coerceIn(0, max)
        if (wanted == now) {
            log("volume: $wanted of $max already set")
            return true
        }
        if (!settings.set(wanted)) {
            log("volume: the phone refused $wanted of $max")
            return false
        }
        awaitLevel(wanted)
        log("volume: set $wanted of $max")
        return true
    }

    /** Best-effort wait for the platform's volume write to become visible. */
    private fun awaitLevel(wanted: Int, timeoutMs: Long = 1_000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (current() == wanted) return
            runCatching { Thread.sleep(20) }
        }
    }

    /**
     * Calls [onChange] with the level and maximum whenever the phone reports a
     * different pair: the platform listener when it exists, plus the poll while
     * a session is up. The dedupe lives here so both sources can stay dumb.
     */
    fun start(onChange: (level: Int, max: Int) -> Unit): AutoCloseable {
        val lock = Object()
        var last: Pair<Int, Int>? = null
        fun emit() {
            val pair = settings.read() ?: return
            synchronized(lock) {
                if (pair == last) return
                last = pair
            }
            onChange(pair.first, pair.second)
        }

        // One read at once: a change made between the state the session
        // already sent and this watcher's start must not be swallowed. The
        // caller's tracker drops the echo when the pair did not move.
        emit()

        val listener = runCatching { settings.listen { emit() } }.getOrNull()
        if (pollIntervalMs <= 0) {
            return AutoCloseable { listener?.close() }
        }
        val stopped = AtomicBoolean(false)
        val thread = Thread({
            while (!stopped.get()) {
                try {
                    Thread.sleep(pollIntervalMs)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                if (stopped.get()) return@Thread
                emit()
            }
        }, "pocketdeck-volume-poll")
        thread.isDaemon = true
        thread.start()
        return AutoCloseable {
            stopped.set(true)
            thread.interrupt()
            listener?.close()
        }
    }
}
