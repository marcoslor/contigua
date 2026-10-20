package dev.pocketdeck.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Debug builds only: posts test notifications on demand, so an emulator can
 * exercise the listener's actions, reply, dismiss and image paths without ever
 * touching a real person's notifications (docs/design/notify.md). Never part of
 * a release build.
 *
 * ```
 * adb shell am broadcast -a dev.pocketdeck.DEBUG_NOTIFY --es kind reply --ei id 7001
 * ```
 *
 * Kinds: `plain`, `buttons` (two actions), `reply` (button + free-form reply),
 * `ongoing`, `code` (a sign-in code), `picture` (a big picture), `icon` (a large
 * icon with alpha), `live` (a ProgressStyle Live Update advancing every 2 s for
 * 20 s) and `chrono` (a countdown chronometer). Actions land in
 * [NotifyDebugResult], which logs the action index and the reply length only —
 * never the text. Pictures are generated test patterns, not anyone's content.
 */
class NotifyDebugPoster : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_POST) return
        val kind = intent.getStringExtra("kind") ?: KIND_PLAIN
        val id = intent.getIntExtra("id", 7001)
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(manager)

        // A new live post replaces the previous run's ticker.
        ticker?.let { LIVE_HANDLER.removeCallbacks(it) }
        ticker = null

        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setAutoCancel(kind != KIND_ONGOING && kind != KIND_LIVE && kind != KIND_CHRONO)
            .setContentIntent(contentIntent(context))
            .setExtras(android.os.Bundle().apply { putBoolean(NotifyEvents.DEBUG_POSTER_EXTRA, true) })

        when (kind) {
            KIND_CODE -> builder.setContentTitle("Sign in").setContentText("Your verification code is 482913")
            KIND_PICTURE -> builder.setContentTitle("Debug picture").setContentText("A generated picture")
            KIND_ICON -> builder.setContentTitle("Debug icon").setContentText("A generated icon")
            KIND_LIVE -> builder.setContentTitle("Debug live update").setContentText("A trip in progress")
            KIND_CHRONO -> builder.setContentTitle("Debug countdown").setContentText("Counting down")
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
            KIND_PICTURE -> builder.setStyle(
                Notification.BigPictureStyle().bigPicture(testPicture(640, 480)),
            )
            KIND_ICON -> builder.setLargeIcon(testIcon(512))
            KIND_LIVE -> builder
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShortCriticalText(LIVE_CHIP)
                .setStyle(progressStyle(0))
            KIND_CHRONO -> builder
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setShortCriticalText(CHRONO_CHIP)
                .setUsesChronometer(true)
                .setChronometerCountDown(true)
                .setWhen(System.currentTimeMillis() + CHRONO_MS)
        }
        manager.notify(id, builder.build())
        Log.i(TAG, "posted kind=$kind id=$id")

        if (kind == KIND_LIVE) startTicking(context, manager, id)
    }

    /** A ProgressStyle with four equal segments: max 100, so the fraction is value/100. */
    private fun progressStyle(value: Int): Notification.ProgressStyle =
        Notification.ProgressStyle()
            .setProgress(value.coerceIn(0, 100))
            .addProgressSegment(Notification.ProgressStyle.Segment(25))
            .addProgressSegment(Notification.ProgressStyle.Segment(25))
            .addProgressSegment(Notification.ProgressStyle.Segment(25))
            .addProgressSegment(Notification.ProgressStyle.Segment(25))

    /** 0 → 100 in steps of 10 every 2 s: 20 s of updates, then it ends. */
    private fun startTicking(context: Context, manager: NotificationManager, id: Int) {
        val app = context.applicationContext
        var step = 0
        val run = object : Runnable {
            override fun run() {
                step += 1
                if (step > LIVE_STEPS) {
                    manager.cancel(id)
                    Log.i(TAG, "live run ended id=$id")
                    return
                }
                val value = step * 10
                val notification = Notification.Builder(app, CHANNEL)
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setAutoCancel(false)
                    .setContentIntent(contentIntent(app))
                    .setExtras(android.os.Bundle().apply { putBoolean(NotifyEvents.DEBUG_POSTER_EXTRA, true) })
                    .setContentTitle("Debug live update")
                    .setContentText("A trip in progress")
                    .setOngoing(true)
                    .setOnlyAlertOnce(true)
                    .setShortCriticalText(LIVE_CHIP)
                    .setStyle(progressStyle(value))
                    .build()
                manager.notify(id, notification)
                Log.i(TAG, "live tick id=$id progress=$value")
                LIVE_HANDLER.postDelayed(this, LIVE_INTERVAL_MS)
            }
        }
        ticker = run
        LIVE_HANDLER.postDelayed(run, LIVE_INTERVAL_MS)
    }

    /** A flat generated picture: a blue field with two light bars. */
    private fun testPicture(width: Int, height: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.rgb(28, 92, 170))
        val paint = Paint().apply { color = Color.rgb(220, 232, 245) }
        canvas.drawRect(width * 0.1f, height * 0.35f, width * 0.9f, height * 0.45f, paint)
        canvas.drawRect(width * 0.1f, height * 0.55f, width * 0.6f, height * 0.62f, paint)
        return bitmap
    }

    /** A generated icon with transparent corners: the alpha path (PNG on the wire). */
    private fun testIcon(size: Int): Bitmap {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawCircle(size / 2f, size / 2f, size * 0.45f, Paint().apply { color = Color.rgb(210, 90, 40) })
        return bitmap
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
        private const val KIND_PICTURE = "picture"
        private const val KIND_ICON = "icon"
        private const val KIND_LIVE = "live"
        private const val KIND_CHRONO = "chrono"
        private const val LIVE_CHIP = "4 min"
        private const val CHRONO_CHIP = "5 min"
        private const val CHRONO_MS = 5 * 60 * 1000L
        private const val LIVE_INTERVAL_MS = 2000L
        private const val LIVE_STEPS = 10
        private val LIVE_HANDLER = Handler(Looper.getMainLooper())
        private var ticker: Runnable? = null
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
