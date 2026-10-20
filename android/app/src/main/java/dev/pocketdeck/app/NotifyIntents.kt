package dev.pocketdeck.app

import android.app.PendingIntent
import android.app.RemoteInput

/**
 * One advertised action of a forwarded notification: the index in the phone's
 * own `Notification.actions`, its PendingIntent and, for a reply action, the
 * free-form RemoteInput that receives the Mac's text.
 */
class NotifyAction(
    val index: Int,
    val intent: PendingIntent,
    val remoteInput: RemoteInput?,
)

/** What the listener keeps for one forwarded id (docs/design/notify.md). */
class NotifyRecord(
    /** The system key `cancelNotification` takes. */
    val key: String,
    val contentIntent: PendingIntent?,
    val actions: List<NotifyAction>,
    val ongoing: Boolean,
    val noClear: Boolean,
) {
    fun action(index: Int): NotifyAction? = actions.firstOrNull { it.index == index }
}

/**
 * The listener's forwarded ids and what they stand for (docs/design/notify.md).
 * The Mac may only name an id the phone itself issued; it never sends an
 * intent, a package or a component. The map is bounded so a long session cannot
 * grow it without limit.
 */
object NotifyIntents {
    private val map = BoundedIdMap<NotifyRecord>(MAX_ENTRIES)

    fun put(id: String, record: NotifyRecord) = map.put(id, record)

    fun get(id: String): NotifyRecord? = map.get(id)

    fun remove(id: String) = map.remove(id)

    fun clear() = map.clear()

    /** 200 forwarded notifications is far more than a person clicks back to. */
    const val MAX_ENTRIES = 200
}
