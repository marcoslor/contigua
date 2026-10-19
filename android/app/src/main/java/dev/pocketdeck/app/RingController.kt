package dev.pocketdeck.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.pocketdeck.R

/**
 * A Mac's `phone.ring` (docs/PROTOCOL.md "Ring"). The shell service has no UI and
 * no audio of its own, so the session asks the app process, which shows
 * [RingActivity] over the lock screen.
 *
 * The activity is started twice on purpose: a high-importance notification with
 * a full-screen intent is the only launch the system performs over a secure
 * keyguard from a background app (Android 14+ needs "full-screen notifications"
 * for it; the Settings grant is one tap), and a direct start covers the case
 * where the app is already in front. Whichever lands first, [RingActivity]
 * plays the alarm; the notification's Stop action ends it from the lock screen.
 */
object RingController {
    const val ACTION_STOP = "dev.pocketdeck.app.RING_STOP"
    const val EXTRA_SECONDS = "seconds"
    const val NOTIFICATION_ID = 42
    private const val CHANNEL_ID = "ring"

    /** Shows the ring (or restarts it) for `seconds`, clamped to 1..30. */
    fun start(context: Context, seconds: Int) {
        val bounded = seconds.coerceIn(1, RingActivity.MAX_SECONDS)
        val ring = Intent(context, RingActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP)
            putExtra(EXTRA_SECONDS, bounded)
        }
        ContextCompat.startActivity(context, ring, null)
        notify(context, ring, bounded)
    }

    /** Silences a running ring; a no-op when nothing rings. */
    fun stop(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
        context.sendBroadcast(Intent(ACTION_STOP).setPackage(context.packageName))
    }

    /** The activity's own end (timeout, Stop button, focus loss). */
    fun cancelNotification(context: Context) {
        NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
    }

    private fun notify(context: Context, ring: Intent, seconds: Int) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) == null) {
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Ringing",
                NotificationManager.IMPORTANCE_HIGH).apply {
                description = "A Mac asked this phone to ring"
                setSound(null, null)
                enableVibration(false)
            })
        }
        val screen = PendingIntent.getActivity(context, 0, ring,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getBroadcast(context, 1,
            Intent(ACTION_STOP).setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(context.getString(R.string.ring_title))
            .setContentText(context.getString(R.string.ring_body))
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(screen)
            .setFullScreenIntent(screen, true)
            .setTimeoutAfter(seconds * 1000L)
            .addAction(0, context.getString(R.string.ring_stop), stop)
            .build()
        runCatching { manager.notify(NOTIFICATION_ID, notification) }
    }
}
