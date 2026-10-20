package dev.pocketdeck.app

/**
 * At most one Live Update per second per forwarded id (docs/design/notify.md).
 * The listener keeps the newest state and sends it when the window opens; this
 * class only answers whether a send is due, so the rule is JVM-tested.
 */
class NotifyLiveThrottle(val intervalMs: Long = 1000L) {
    private val lastSent = HashMap<String, Long>()

    /** True when this id may be sent now, and marks it sent. */
    fun due(id: String, nowMs: Long): Boolean {
        val previous = lastSent[id]
        if (previous != null && nowMs - previous < intervalMs) return false
        lastSent[id] = nowMs
        return true
    }

    /** Milliseconds until this id may be sent again (0 when it is due now). */
    fun waitMs(id: String, nowMs: Long): Long {
        val last = lastSent[id] ?: return 0
        return (last + intervalMs - nowMs).coerceAtLeast(0)
    }

    /** The phone took the notification away (or the session ended). */
    fun forget(id: String) {
        lastSent.remove(id)
    }

    fun clear() = lastSent.clear()
}
