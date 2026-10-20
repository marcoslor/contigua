package dev.pocketdeck.server

import java.util.concurrent.atomic.AtomicBoolean

/**
 * The phone's Do Not Disturb (docs/design/focus.md): the Mac's `phone.dnd`
 * command, the memory of what PocketDeck itself turned on, and the restore
 * rule that never turns off a person's own DND.
 *
 * The memory belongs to the shell service, not a session: a Mac that goes away
 * and comes back must still know whether the DND is PocketDeck's. It is
 * cleared on reboot, which the design accepts.
 */
class ZenControl(
    private val settings: ZenSettings,
    private val setter: ZenSetter,
    private val log: (String) -> Unit = {},
    /** Re-read interval when no ContentObserver is reachable; 0 disables polling. */
    private val pollIntervalMs: Long = 5_000,
) {

    /** The mode PocketDeck turned on; null when the current DND is the person's. */
    @Volatile
    private var owned: DndMode? = null

    val setByMac: DndMode? get() = owned

    /** The mode the phone reports now; null when unreadable. */
    fun current(): DndMode? = settings.read()

    /**
     * One Mac command. Returns true when the phone's mode changed.
     *
     * On never takes over a DND the person already had; off only clears what
     * PocketDeck set, and only while the phone is still in that mode.
     */
    @Synchronized
    fun apply(wanted: DndMode): Boolean {
        val now = current()
        if (now == null) {
            log("dnd: mode unreadable; left alone")
            return false
        }
        if (wanted == DndMode.OFF) return restore(now)
        if (now == wanted) {
            when (owned) {
                wanted -> log("dnd: $wanted already on; nothing to do")
                null -> log("dnd: person's own $now; left alone")
                else -> log("dnd: $wanted already on; nothing to do")
            }
            // Same mode as before: a reconnect must not claim or re-apply it.
            if (owned != wanted) owned = null
            return false
        }
        if (now != DndMode.OFF) {
            owned = null
            log("dnd: person's own $now; left alone")
            return false
        }
        if (!setter.set(wanted)) {
            log("dnd: the phone refused $wanted")
            return false
        }
        owned = wanted
        // `cmd notification` returns before a Settings write can be visible;
        // wait briefly so the state this session sends next is the new mode.
        awaitMode(wanted)
        log("dnd: set $wanted")
        return true
    }

    private fun restore(now: DndMode): Boolean {
        val mine = owned
        if (mine == null) {
            log("dnd: ${now.wire} is not ours; left alone")
            return false
        }
        owned = null
        if (now != mine) {
            log("dnd: person changed to ${now.wire}; left alone")
            return false
        }
        if (!setter.set(DndMode.OFF)) {
            log("dnd: the phone refused off")
            return false
        }
        awaitMode(DndMode.OFF)
        log("dnd: restored off")
        return true
    }

    /** Best-effort wait for the platform's Settings write to become visible. */
    private fun awaitMode(wanted: DndMode, timeoutMs: Long = 1_000) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (current() == wanted) return
            runCatching { Thread.sleep(20) }
        }
    }

    /**
     * A mode seen by the observer or the poller: a change away from what
     * PocketDeck set means the person owns the DND now.
     */
    @Synchronized
    fun observed(mode: DndMode?) {
        val mine = owned ?: return
        if (mode != mine) {
            owned = null
            log("dnd: person changed to ${mode?.wire ?: "unknown"}; left alone")
        }
    }

    /**
     * Watches the setting while a session is up: the platform observer when
     * the shell UID can register one, else a poll of at most [pollIntervalMs].
     * On change only, so the state stream stays "sent on change".
     */
    fun start(onChange: (DndMode?) -> Unit): AutoCloseable {
        val listener = runCatching {
            settings.listen { mode ->
                observed(mode)
                onChange(mode)
            }
        }.getOrNull()
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
                observed(mode)
                onChange(mode)
            }
        }, "pocketdeck-dnd-poll")
        thread.isDaemon = true
        thread.start()
        log("dnd: polling every ${pollIntervalMs}ms (no observer)")
        return AutoCloseable {
            stopped.set(true)
            thread.interrupt()
        }
    }
}
