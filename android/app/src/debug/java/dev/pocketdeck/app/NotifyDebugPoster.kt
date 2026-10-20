package dev.pocketdeck.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Debug builds only: posts test notifications on demand, so an emulator can
 * exercise the listener's actions, reply and dismiss paths without ever
 * touching a real person's notifications (docs/design/notify.md). Never part of
 * a release build.
 *
 * ```
 * adb shell am broadcast -a dev.pocketdeck.DEBUG_NOTIFY --es kind reply --ei id 7001
 * ```
 *
 * Kinds: `plain`, `buttons` (two actions), `reply` (button + free-form reply),
 * `ongoing`, `code` (a sign-in code). Actions land in [NotifyDebugResult],
 * which logs the action index and the reply length only — never the text.
 */
class NotifyDebugPoster : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_POST) return
        val kind = intent.getStringExtra("kind") ?: KIND_PLAIN
        val id = intent.getIntExtra("id", 7001)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(manager)

        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setAutoCancel(kind != KIND_ONGOING)
            .setContentIntent(contentIntent(context))
            .setExtras(android.os.Bundle().apply { putBoolean(NotifyEvents.DEBUG_POSTER_EXTRA, true) })

        when (kind) {
            KIND_CODE -> builder.setContentTitle("Sign in").setContentText("Your verification code is 482913")
            else -> builder.setContentTitle("Debug notification").setContentText("Nothing to answer here")
        }
        when (kind) {
            KIND_BUTTONS -> {
                builder.addAction(action(context, 0, "Mark as read"))
                builder.addAction(action(context, 1, "Archive"))
            }
            KIND_REPLY -> {
                builder.addAction(action(context, 0, "Mark as read"))
                builder.addAction(replyAction(context, 1))
            }
            KIND_ONGOING -> builder.setOngoing(true)
        }
        manager.notify(id, builder.build())
        Log.i(TAG, "posted kind=$kind id=$id")
    }

    private fun contentIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            8000,
            Intent(context, NotifyDebugResult::class.java).putExtra("i", -1),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

    private fun action(context: Context, index: Int, title: String): Notification.Action =
        Notification.Action.Builder(null, title, resultIntent(context, index)).build()

    private fun replyAction(context: Context, index: Int): Notification.Action {
        val remote = RemoteInput.Builder(KEY_REPLY).setLabel("Reply").build()
        return Notification.Action.Builder(null, "Reply", resultIntent(context, index))
            .addRemoteInput(remote)
            .build()
    }

    private fun resultIntent(context: Context, index: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            9000 + index,
            Intent(context, NotifyDebugResult::class.java).putExtra("i", index),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )

    private fun ensureChannel(manager: NotificationManager) {
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "PocketDeck debug", NotificationManager.IMPORTANCE_HIGH),
        )
    }

    companion object {
        const val ACTION_POST = "dev.pocketdeck.DEBUG_NOTIFY"
        const val KEY_REPLY = "reply"
        const val TAG = "PdNotifyDebug"
        private const val CHANNEL = "pd-debug-notify"
        private const val KIND_PLAIN = "plain"
        private const val KIND_BUTTONS = "buttons"
        private const val KIND_REPLY = "reply"
        private const val KIND_ONGOING = "ongoing"
        private const val KIND_CODE = "code"
    }
}

/** The test notification's actions land here: index and length only. */
class NotifyDebugResult : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val index = intent.getIntExtra("i", -1)
        val reply = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(NotifyDebugPoster.KEY_REPLY)
        Log.i(
            NotifyDebugPoster.TAG,
            "action i=$index replyLen=${reply?.length ?: 0}",
        )
    }
}
