package app.contigua.app

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context

/**
 * Whether the phone has granted Contigua's notification listener. This is the
 * phone-side half of the notification gate (docs/design/notify.md); the Mac's
 * per-phone switch is the only person-facing one.
 */
object NotifyAccess {

    fun component(context: Context): ComponentName =
        ComponentName(context.packageName, PdNotificationListener::class.java.name)

    fun isGranted(context: Context): Boolean = runCatching {
        context.getSystemService(NotificationManager::class.java)
            .isNotificationListenerAccessGranted(component(context))
    }.getOrDefault(false)
}
