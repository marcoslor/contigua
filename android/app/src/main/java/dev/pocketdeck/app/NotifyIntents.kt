package dev.pocketdeck.app

import android.app.PendingIntent

/**
 * The listener's forwarded ids and their notification actions (docs/design/
 * notify.md). The Mac may only name an id the phone itself issued; it never
 * sends an intent, a package or a component. The map is bounded so a long
 * session cannot grow it without limit.
 */
object NotifyIntents {
    private val map = BoundedIdMap<PendingIntent>(MAX_ENTRIES)

    fun put(id: String, intent: PendingIntent) = map.put(id, intent)

    fun get(id: String): PendingIntent? = map.get(id)

    fun remove(id: String) = map.remove(id)

    fun clear() = map.clear()

    /** 200 forwarded notifications is far more than a person clicks back to. */
    const val MAX_ENTRIES = 200
}
