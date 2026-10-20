package dev.pocketdeck.server

import java.util.concurrent.atomic.AtomicBoolean

/**
 * The phone's ringer mode (docs/design/controls.md): the Mac's `phone.ringer`
 * command, read back from `Settings.Global.mode_ringer`.
 *
 * The write path is `cmd audio set-ringer-mode` at shell UID and nothing else:
 * no stream volume, no lock setting, no other phone setting. On API 36 a ringer
 * change while the phone is in the "alarms" DND ends that DND, so the control
 * refuses every write while Do Not Disturb is on; the Mac refuses the same
 * request before it sends (the snapshot's `dnd`), and this is the second gate.
 */
class RingerControl(
    private val settings: RingerSettings,
    private val setter: RingerSetter,
    /** The phone's DND now; null when unreadable (treated as off). */
    private val dnd: () -> DndMode? = { null },
    private val log: (String) -> Unit = {},
    /** Re-read interval when no ContentObserver is reachable; 0 disables polling. */
    private val pollIntervalMs: Long = 5_000,
) {

    /** What one Mac command did. */
    enum class Result {
        /** The phone's ringer changed. */
        SET,
        /** It already held that mode; nothing was written. */
        SAME,
        /** Do Not Disturb is on; the write is refused rather than end that DND. */
        REFUSED_DND,
        /** The phone would not write the setting. */
        REFUSED,
        /** The current mode cannot be read; nothing is written. */
        UNREADABLE,
    }

    /** The mode the phone reports now; null when unreadable. */
    fun current(): RingerMode? = settings.read()

    @Synchronized
    fun apply(wanted: RingerMode): Result {
        val now = settings.read() ?: run {
            log("ringer: mode unreadable; left alone")
            return Result.UNREADABLE
        }
        if (dnd()?.isOn == true) {
            log("ringer: DND is on; refused ${wanted.wire}")
            return Result.REFUSED_DND
        }
        if (now == wanted) {
            log("ringer: ${wanted.wire} already set")
            return Result.SAME
        }
        if (!setter.set(wanted)) {
            log("ringer: the phone refused ${wanted.wire}")
            return Result.REFUSED
        }
        awaitMode(wanted)
        log("ringer: set ${wanted.wire}")
        return Result.SET
    }

    /** Best-effort wait for the platform's Settings write to become visible. */
    private fun awaitMode(wanted: RingerMode, timeoutMs: Long = 1_000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (current() == wanted) return
            runCatching { Thread.sleep(20) }
        }
    }

    /** A mode seen by the observer or the poller; the session sends it as state. */
    fun start(onChange: (RingerMode?) -> Unit): AutoCloseable {
        val listener = runCatching { settings.listen(onChange) }.getOrNull()
        if (listener != null) return listener
        if (pollIntervalMs <= 0) return AutoCloseable { }
        val stopped = AtomicBoolean(false)
        var last = current()
        val thread = Thread({
            while (!stopped.get()) {
                try {
                    Thread.sleep(pollIntervalMs)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                if (stopped.get()) return@Thread
                val mode = current() ?: continue
                if (mode == last) continue
                last = mode
                onChange(mode)
            }
        }, "pocketdeck-ringer-poll")
        thread.isDaemon = true
        thread.start()
        log("ringer: polling every ${pollIntervalMs}ms (no observer)")
        return AutoCloseable {
            stopped.set(true)
            thread.interrupt()
        }
    }
}
